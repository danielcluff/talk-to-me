//! The core: one playback queue, one engine thread, one audio output.
//!
//! Threads
//!   - engine thread: the only thread that touches the TTS engine. It loads
//!     the model lazily, synthesizes the current job's next chunks (one ahead
//!     of playback) and the next job's first chunk, pauses the audio hardware
//!     when idle, and unloads the model after `idle_unload_minutes`.
//!   - AudioQueue thread: `pull()` copies PCM of the current chunk, advances
//!     the cursor and moves to the next job. No allocation, no blocking.
//!   - API threads: enqueue jobs and change the cursor (pause/next/stop...).
//!
//! All shared state is guarded by one pthread mutex (`mu`); the audio thread
//! is not an `Io` thread, so plain pthreads are used. `player_mu` serializes
//! AudioQueue start/pause and is never taken while `mu` is held (priming the
//! queue calls `pull()`, which takes `mu`).

const std = @import("std");
const Io = std.Io;
const c = @import("c");
const config = @import("config.zig");
const models = @import("models/models.zig");
const markdown = @import("text/markdown.zig");
const chunker = @import("text/chunk.zig");
const dictionary = @import("text/dictionary.zig");

const log = std.log.scoped(.core);

// ------------------------------------------------------------------ sync

const Mutex = struct {
    m: std.c.pthread_mutex_t = .{},
    fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.m);
    }
    fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.m);
    }
};

const Cond = struct {
    cv: std.c.pthread_cond_t = .{},
    fn wait(self: *Cond, m: *Mutex) void {
        _ = std.c.pthread_cond_wait(&self.cv, &m.m);
    }
    fn timedWait(self: *Cond, m: *Mutex, ms: u64) void {
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &now);
        var ns: i64 = @as(i64, now.nsec) + @as(i64, @intCast(ms % 1000)) * std.time.ns_per_ms;
        var sec: i64 = now.sec + @as(i64, @intCast(ms / 1000));
        if (ns >= std.time.ns_per_s) {
            sec += 1;
            ns -= std.time.ns_per_s;
        }
        const deadline: std.c.timespec = .{ .sec = @intCast(sec), .nsec = @intCast(ns) };
        _ = std.c.pthread_cond_timedwait(&self.cv, &m.m, &deadline);
    }
    fn signal(self: *Cond) void {
        _ = std.c.pthread_cond_signal(&self.cv);
    }
    fn broadcast(self: *Cond) void {
        _ = std.c.pthread_cond_broadcast(&self.cv);
    }
};

// ------------------------------------------------------------------ types

pub const Policy = enum { queue, interrupt, replace, drop_if_busy };

pub const Format = enum { markdown, text };

pub const Source = struct {
    app: []const u8 = "cli",
    label: []const u8 = "",
    session: []const u8 = "",
};

pub const SpeakRequest = struct {
    text: ?[]const u8 = null,
    /// pre-split sentences (browser); used as-is instead of `text`
    chunks: ?[]const []const u8 = null,
    format: Format = .markdown,
    source: Source = .{},
    voice: ?[]const u8 = null,
    speed: ?f32 = null,
    policy: Policy = .queue,
};

pub const SpeakResult = union(enum) {
    queued: struct { id: u64, chunks: usize, position: usize },
    dropped: []const u8, // reason
};

pub const FinishReason = enum { done, skipped, stopped, interrupted, replaced, removed, failed };

pub const JobState = enum { queued, playing, done, skipped, stopped, interrupted, replaced, removed, failed };

const Job = struct {
    id: u64,
    arena: std.heap.ArenaAllocator,
    source: Source,
    voice: []const u8, // empty: resolve at synthesis time
    speed: f32,
    chunks: []chunker.Chunk,
    /// per-chunk PCM (gpa); null until synthesized, empty slice on failure
    audio: []?[]f32,
    preview: []const u8,
    hash: u64,
    created_ms: i64,
};

pub const Summary = struct {
    id: u64,
    app: [24]u8 = @splat(0),
    label: [48]u8 = @splat(0),
    preview: [120]u8 = @splat(0),
    chunks: u32,
    state: JobState,
    /// wall-clock milliseconds when it finished
    finished_ms: i64 = 0,

    fn str(buf: []const u8) []const u8 {
        return std.mem.sliceTo(buf, 0);
    }
};

pub const EventKind = enum { job_queued, job_started, chunk_started, job_finished, player_state, model_state, pair_request };

pub const Event = struct {
    seq: u64 = 0,
    kind: EventKind,
    job: u64 = 0,
    index: u32 = 0,
    count: u32 = 0,
    state: [16]u8 = @splat(0),

    fn withState(e: Event, s: []const u8) Event {
        var out = e;
        const n = @min(s.len, out.state.len);
        @memcpy(out.state[0..n], s[0..n]);
        return out;
    }

    pub fn stateStr(e: *const Event) []const u8 {
        return std.mem.sliceTo(&e.state, 0);
    }
};

const ModelLoad = enum { unloaded, loading, loaded, failed };

const event_ring = 512;
const history_len = 50;

/// Full text of a history entry, filled in by the engine thread when it frees
/// the job (the audio thread, which often finishes jobs, never allocates).
const HistoryText = struct { id: u64, text: []u8 };

// ------------------------------------------------------------------ core

pub const Core = struct {
    gpa: std.mem.Allocator,
    io: Io,
    paths: config.Paths,
    catalog: models.Catalog,

    mu: Mutex = .{},
    work_cv: Cond = .{}, // engine thread wakeups
    events_cv: Cond = .{}, // SSE readers
    load_cv: Cond = .{}, // waiters for a model load

    // settings (strings owned by settings_arena), guarded by mu
    settings_arena: std.heap.ArenaAllocator,
    settings: config.Settings,

    // queue, guarded by mu
    next_id: u64 = 1,
    pending: std.ArrayList(*Job) = .empty,
    current: ?*Job = null,
    cursor_chunk: usize = 0,
    cursor_sample: usize = 0,
    gap_left: usize = 0,
    chunk_announced: bool = false,
    paused: bool = false,
    graveyard: std.ArrayList(*Job) = .empty,
    history: [history_len]Summary = undefined,
    history_text: [history_len]?HistoryText = @splat(null),
    history_count: usize = 0,
    history_head: usize = 0,

    // events, guarded by mu
    events: [event_ring]Event = undefined,
    event_seq: u64 = 0,

    // engine, owned by the engine thread; the scalars are read under mu
    engine: ?*c.te_engine = null,
    engine_model: []const u8 = "", // id of the loaded model (static string from catalog)
    load_state: ModelLoad = .unloaded,
    load_error: [160]u8 = @splat(0),
    load_requested: bool = false,
    sample_rate: u32 = 0,
    channels: u32 = 1,
    voices: std.ArrayList([]const u8) = .empty, // owned by voices_arena
    voices_arena: std.heap.ArenaAllocator,
    last_active_ms: i64 = 0,
    shutting_down: bool = false,

    // audio output; created on first load, guarded by player_mu
    player_mu: Mutex = .{},
    player: ?*c.ta_player = null,
    player_rate: u32 = 0,

    // downloads (one at a time), guarded by mu
    download_model: []const u8 = "",
    download_progress: models.Progress = .{},
    download_error: [160]u8 = @splat(0),
    download_thread: ?std.Thread = null,

    engine_thread: ?std.Thread = null,

    pub fn create(gpa: std.mem.Allocator, io: Io, paths: config.Paths, settings: config.Settings) !*Core {
        const self = try gpa.create(Core);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .paths = paths,
            .catalog = try models.Catalog.load(gpa),
            .settings_arena = .init(gpa),
            .settings = undefined,
            .voices_arena = .init(gpa),
        };
        self.settings = try dupeSettings(self.settings_arena.allocator(), settings);
        self.last_active_ms = self.nowMs();
        self.engine_thread = try std.Thread.spawn(.{}, engineMain, .{self});
        return self;
    }

    pub fn destroy(self: *Core) void {
        self.mu.lock();
        self.shutting_down = true;
        self.work_cv.broadcast();
        self.mu.unlock();
        if (self.engine_thread) |t| t.join();
        if (self.download_thread) |t| t.join();
        self.player_mu.lock();
        if (self.player) |p| c.ta_player_free(p);
        self.player_mu.unlock();
        if (self.engine) |e| c.te_free(e);
        if (self.current) |j| self.freeJob(j);
        for (self.pending.items) |j| self.freeJob(j);
        for (self.graveyard.items) |j| self.freeJob(j);
        self.pending.deinit(self.gpa);
        self.graveyard.deinit(self.gpa);
        for (self.history_text) |maybe| if (maybe) |h| self.gpa.free(h.text);
        self.voices_arena.deinit();
        self.settings_arena.deinit();
        self.catalog.deinit();
        self.gpa.destroy(self);
    }

    fn nowMs(self: *Core) i64 {
        const ns = Io.Timestamp.now(self.io, .awake).toNanoseconds();
        return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    fn dupeSettings(a: std.mem.Allocator, s: config.Settings) !config.Settings {
        var out = s;
        out.model = try a.dupe(u8, s.model);
        out.voice = try a.dupe(u8, s.voice);
        const origins = try a.alloc([]const u8, s.paired_origins.len);
        for (s.paired_origins, origins) |o, *d| d.* = try a.dupe(u8, o);
        out.paired_origins = origins;
        const dict = try a.alloc(dictionary.Entry, s.dictionary.len);
        for (s.dictionary, dict) |e, *d| d.* = .{ .from = try a.dupe(u8, e.from), .to = try a.dupe(u8, e.to), .case_sensitive = e.case_sensitive };
        out.dictionary = dict;
        out.sources = .{};
        var it = s.sources.map.iterator();
        while (it.next()) |e| {
            var v = e.value_ptr.*;
            v.voice = try a.dupe(u8, v.voice);
            try out.sources.map.put(a, try a.dupe(u8, e.key_ptr.*), v);
        }
        return out;
    }

    // ------------------------------------------------------------ settings

    pub fn getSettings(self: *Core, arena: std.mem.Allocator) !config.Settings {
        self.mu.lock();
        defer self.mu.unlock();
        return dupeSettings(arena, self.settings);
    }

    /// Replace the settings (already validated by the caller) and persist them.
    pub fn setSettings(self: *Core, s: config.Settings) !void {
        if (self.catalog.find(s.model) == null) return error.UnknownModel;
        var fresh: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer fresh.deinit();
        const copy = try dupeSettings(fresh.allocator(), s);
        try config.saveSettings(self.gpa, self.io, self.paths, copy);
        self.mu.lock();
        self.settings_arena.deinit();
        self.settings_arena = fresh;
        self.settings = copy;
        self.work_cv.broadcast(); // a model change is picked up by the engine thread
        self.mu.unlock();
    }

    // ------------------------------------------------------------ events

    /// Post an event from outside the core (e.g. a pairing request).
    pub fn emit(self: *Core, e: Event) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.pushEvent(e);
    }

    pub fn eventWithState(kind: EventKind, index: u32, state: []const u8) Event {
        return (Event{ .kind = kind, .index = index }).withState(state);
    }

    fn pushEvent(self: *Core, e: Event) void {
        // caller holds mu
        self.event_seq += 1;
        var ev = e;
        ev.seq = self.event_seq;
        self.events[self.event_seq % event_ring] = ev;
        self.events_cv.broadcast();
    }

    /// Copy events with seq > after into out; waits up to timeout_ms for one.
    /// Returns the number copied. If the reader fell behind the ring, it
    /// resumes at the oldest kept event.
    pub fn waitEvents(self: *Core, after: u64, out: []Event, timeout_ms: u64) usize {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.event_seq <= after and !self.shutting_down) self.events_cv.timedWait(&self.mu, timeout_ms);
        var from = after + 1;
        if (self.event_seq >= event_ring and from + event_ring <= self.event_seq) from = self.event_seq - event_ring + 1;
        var n: usize = 0;
        var s = from;
        while (s <= self.event_seq and n < out.len) : (s += 1) {
            out[n] = self.events[s % event_ring];
            n += 1;
        }
        return n;
    }

    pub fn currentSeq(self: *Core) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.event_seq;
    }

    // ------------------------------------------------------------ jobs

    /// The job's text: its chunks, with blank lines where blocks end.
    fn jobText(gpa: std.mem.Allocator, j: *const Job) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (j.chunks, 0..) |ch, i| {
            if (i > 0) try out.appendSlice(gpa, if (j.chunks[i - 1].pause_after_ms > 0) "\n\n" else " ");
            try out.appendSlice(gpa, ch.text);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Engine thread, with mu held: keep the text of a job that is in history.
    fn keepHistoryText(self: *Core, j: *const Job) void {
        var k: usize = 0;
        while (k < self.history_count) : (k += 1) {
            if (self.history[k].id != j.id) continue;
            const text = jobText(self.gpa, j) catch return;
            if (self.history_text[k]) |old| self.gpa.free(old.text);
            self.history_text[k] = .{ .id = j.id, .text = text };
            return;
        }
    }

    fn historyTextFor(self: *Core, id: u64) ?[]const u8 {
        for (self.history_text) |maybe| if (maybe) |h| {
            if (h.id == id) return h.text;
        };
        return null;
    }

    fn freeJob(self: *Core, j: *Job) void {
        self.keepHistoryText(j);
        for (j.audio) |maybe| if (maybe) |pcm| {
            if (pcm.len > 0) self.gpa.free(pcm);
        };
        j.arena.deinit();
        self.gpa.destroy(j);
    }

    fn summarize(j: *const Job, state: JobState) Summary {
        var s: Summary = .{ .id = j.id, .chunks = @intCast(j.chunks.len), .state = state };
        copyTrunc(&s.app, j.source.app);
        copyTrunc(&s.label, j.source.label);
        copyTrunc(&s.preview, j.preview);
        return s;
    }

    fn copyTrunc(dst: []u8, src: []const u8) void {
        const n = @min(dst.len - 1, src.len);
        @memcpy(dst[0..n], src[0..n]);
        dst[n] = 0;
    }

    fn recordHistory(self: *Core, j: *const Job, state: JobState) void {
        var sum = summarize(j, state);
        var now: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &now) == 0) sum.finished_ms = @as(i64, now.sec) * 1000 + @divTrunc(@as(i64, now.nsec), std.time.ns_per_ms);
        self.history[self.history_head] = sum;
        self.history_head = (self.history_head + 1) % history_len;
        if (self.history_count < history_len) self.history_count += 1;
    }

    /// Retire a job (caller holds mu). The engine thread frees it later.
    fn retire(self: *Core, j: *Job, reason: FinishReason) void {
        const state: JobState = switch (reason) {
            .done => .done,
            .skipped => .skipped,
            .stopped => .stopped,
            .interrupted => .interrupted,
            .replaced => .replaced,
            .removed => .removed,
            .failed => .failed,
        };
        self.recordHistory(j, state);
        self.pushEvent((Event{ .kind = .job_finished, .job = j.id, .count = @intCast(j.chunks.len) }).withState(@tagName(reason)));
        self.graveyard.append(self.gpa, j) catch self.freeJobLater(j);
        self.work_cv.signal();
    }

    fn freeJobLater(self: *Core, j: *Job) void {
        // graveyard append failed (OOM): leak rather than free under the
        // audio thread's feet.
        _ = self;
        _ = j;
    }

    /// Make `j` the current job (caller holds mu, current must be null).
    fn startJob(self: *Core, j: *Job) void {
        self.current = j;
        self.cursor_chunk = 0;
        self.cursor_sample = 0;
        self.gap_left = 0;
        self.chunk_announced = false;
        self.pushEvent(.{ .kind = .job_started, .job = j.id, .count = @intCast(j.chunks.len) });
        self.work_cv.signal();
    }

    /// Finish the current job and move to the next pending one (caller holds mu).
    fn advanceJob(self: *Core, reason: FinishReason) void {
        if (self.current) |j| {
            self.current = null;
            self.retire(j, reason);
        }
        if (self.pending.items.len > 0) {
            const next = self.pending.orderedRemove(0);
            self.startJob(next);
        }
    }

    fn hashText(app: []const u8, chunks: []const chunker.Chunk) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(app);
        for (chunks) |ch| h.update(ch.text);
        return h.final();
    }

    pub fn speak(self: *Core, req: SpeakRequest) !SpeakResult {
        const j = try self.gpa.create(Job);
        errdefer self.gpa.destroy(j);
        j.arena = .init(self.gpa);
        errdefer j.arena.deinit();
        const a = j.arena.allocator();

        // a deep copy: settings strings and lists live in an arena that a
        // settings change frees while this request is still running
        const s = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            break :blk try dupeSettings(a, self.settings);
        };

        // text → blocks → chunks (outside the lock)
        if (req.chunks) |pre| {
            var list: std.ArrayList(chunker.Chunk) = .empty;
            for (pre) |t| {
                const trimmed = std.mem.trim(u8, t, " \t\r\n");
                if (trimmed.len > 0) try list.append(a, .{ .text = try a.dupe(u8, try dictionary.apply(a, trimmed, s.dictionary)) });
            }
            j.chunks = list.items;
        } else {
            const text = req.text orelse return error.MissingText;
            var blocks = switch (req.format) {
                .markdown => try markdown.toBlocks(self.gpa, text, .{ .code_blocks = s.code_blocks, .tables = s.tables }),
                .text => try markdown.plainToBlocks(self.gpa, text),
            };
            defer blocks.deinit();
            const spoken = try a.alloc([]const u8, blocks.items.len);
            for (blocks.items, spoken) |b, *o| o.* = try dictionary.apply(a, b, s.dictionary);
            const raw = try chunker.chunk(self.gpa, spoken, .{});
            defer self.gpa.free(raw);
            j.chunks = try a.alloc(chunker.Chunk, raw.len);
            for (raw, j.chunks) |src, *dst| dst.* = .{ .text = try a.dupe(u8, src.text), .pause_after_ms = src.pause_after_ms };
        }
        if (j.chunks.len == 0) {
            j.arena.deinit();
            self.gpa.destroy(j);
            return .{ .dropped = "nothing to speak" };
        }
        // per-source settings: mute, voice, announcement
        const src = s.sources.map.get(req.source.app);
        if (src) |ss| if (!ss.enabled) {
            j.arena.deinit();
            self.gpa.destroy(j);
            return .{ .dropped = "muted" };
        };
        if (src) |ss| if (ss.announce) {
            const who = config.sourceName(req.source.app);
            const intro = if (req.source.label.len > 0)
                try std.fmt.allocPrint(a, "{s}, in {s}.", .{ who, req.source.label })
            else
                try std.fmt.allocPrint(a, "{s}.", .{who});
            const with = try a.alloc(chunker.Chunk, j.chunks.len + 1);
            with[0] = .{ .text = intro, .pause_after_ms = 150 };
            @memcpy(with[1..], j.chunks);
            j.chunks = with;
        };
        const source_voice: ?[]const u8 = if (src) |ss| (if (ss.voice.len > 0) ss.voice else null) else null;
        j.audio = try a.alloc(?[]f32, j.chunks.len);
        @memset(j.audio, null);
        j.source = .{
            .app = try a.dupe(u8, req.source.app),
            .label = try a.dupe(u8, req.source.label),
            .session = try a.dupe(u8, req.source.session),
        };
        j.voice = try a.dupe(u8, req.voice orelse source_voice orelse "");
        j.speed = req.speed orelse s.speed;
        const first = j.chunks[if (j.chunks.len > 1 and src != null and src.?.announce) 1 else 0].text;
        j.preview = first[0..@min(first.len, 119)];
        j.hash = hashText(j.source.app, j.chunks);
        j.created_ms = self.nowMs();

        self.mu.lock();
        // dedupe: same source and text within the window. Only for agent-style
        // policies; something you start yourself (interrupt) always plays.
        const window: i64 = @as(i64, self.settings.dedupe_seconds) * 1000;
        if (window > 0 and req.policy != .interrupt) {
            const dup = for (self.pending.items) |p| {
                if (p.hash == j.hash and j.created_ms - p.created_ms < window) break true;
            } else if (self.current) |cur| cur.hash == j.hash and j.created_ms - cur.created_ms < window else false;
            if (dup) {
                self.mu.unlock();
                j.arena.deinit();
                self.gpa.destroy(j);
                return .{ .dropped = "duplicate" };
            }
        }
        if (req.policy == .drop_if_busy and self.current != null) {
            self.mu.unlock();
            j.arena.deinit();
            self.gpa.destroy(j);
            return .{ .dropped = "busy" };
        }
        // retire() runs on the audio thread too; keep room so it never allocates there
        self.graveyard.ensureUnusedCapacity(self.gpa, self.pending.items.len + 2) catch {};
        self.next_id += 1;
        j.id = self.next_id - 1;
        if (req.policy == .replace and j.source.session.len > 0) {
            var i: usize = 0;
            while (i < self.pending.items.len) {
                const p = self.pending.items[i];
                if (std.mem.eql(u8, p.source.session, j.source.session)) {
                    _ = self.pending.orderedRemove(i);
                    self.retire(p, .replaced);
                } else i += 1;
            }
        }
        self.pushEvent(.{ .kind = .job_queued, .job = j.id, .count = @intCast(j.chunks.len) });
        var position: usize = 0;
        if (req.policy == .interrupt) {
            if (self.current) |cur| {
                self.current = null;
                self.retire(cur, .interrupted);
            }
            self.paused = false;
            self.startJob(j);
        } else if (self.current == null) {
            self.startJob(j);
        } else {
            self.pending.append(self.gpa, j) catch |err| {
                self.mu.unlock();
                j.arena.deinit();
                self.gpa.destroy(j);
                return err;
            };
            position = self.pending.items.len;
        }
        const id = j.id;
        const n = j.chunks.len;
        self.work_cv.signal();
        self.mu.unlock();
        self.ensurePlaying();
        return .{ .queued = .{ .id = id, .chunks = n, .position = position } };
    }

    pub fn removeJob(self: *Core, id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.current) |cur| if (cur.id == id) {
            self.advanceJob(.removed);
            return true;
        };
        for (self.pending.items, 0..) |p, i| {
            if (p.id == id) {
                _ = self.pending.orderedRemove(i);
                self.retire(p, .removed);
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------ transport

    pub const Command = enum { pause, @"resume", toggle, stop, next, previous, skip };

    pub fn command(self: *Core, cmd: Command) void {
        self.mu.lock();
        const was_paused = self.paused;
        switch (cmd) {
            .pause => self.paused = true,
            .@"resume" => self.paused = false,
            .toggle => self.paused = !self.paused,
            .stop => {
                for (self.pending.items) |p| self.retire(p, .stopped);
                self.pending.clearRetainingCapacity();
                if (self.current) |cur| {
                    self.current = null;
                    self.retire(cur, .stopped);
                }
                self.paused = false;
            },
            .skip => self.advanceJob(.skipped),
            .next => if (self.current) |cur| {
                if (self.cursor_chunk + 1 >= cur.chunks.len) {
                    self.advanceJob(.skipped);
                } else {
                    self.cursor_chunk += 1;
                    self.cursor_sample = 0;
                    self.gap_left = 0;
                    self.chunk_announced = false;
                }
            },
            .previous => if (self.current != null) {
                // restart the sentence if more than 1.5 s in, else go back one
                const threshold = (self.sample_rate * 3) / 2;
                if (self.cursor_sample <= threshold and self.cursor_chunk > 0) self.cursor_chunk -= 1;
                self.cursor_sample = 0;
                self.gap_left = 0;
                self.chunk_announced = false;
            },
        }
        if (was_paused != self.paused) self.pushEvent((Event{ .kind = .player_state }).withState(if (self.paused) "paused" else "playing"));
        self.work_cv.signal();
        self.mu.unlock();
        self.ensurePlaying();
    }

    // ------------------------------------------------------------ audio path

    fn pullCb(user: ?*anyopaque, out: [*c]f32, n_frames: usize) callconv(.c) usize {
        const self: *Core = @ptrCast(@alignCast(user.?));
        return self.pull(out[0 .. n_frames * self.channels], n_frames);
    }

    /// AudioQueue thread. Fills `out` (interleaved) and returns frames written.
    fn pull(self: *Core, out: []f32, n_frames: usize) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const ch = self.channels;
        var written: usize = 0;
        while (written < n_frames) {
            if (self.paused) break;
            const j = self.current orelse break;
            if (self.gap_left > 0) {
                const n = @min(self.gap_left, n_frames - written);
                @memset(out[written * ch .. (written + n) * ch], 0);
                written += n;
                self.gap_left -= n;
                continue;
            }
            if (self.cursor_chunk >= j.chunks.len) {
                self.advanceJob(.done);
                continue;
            }
            const pcm = j.audio[self.cursor_chunk] orelse break; // underrun: not synthesized yet
            if (!self.chunk_announced) {
                self.chunk_announced = true;
                self.pushEvent(.{ .kind = .chunk_started, .job = j.id, .index = @intCast(self.cursor_chunk), .count = @intCast(j.chunks.len) });
                self.work_cv.signal(); // prefetch the next chunk
            }
            const frames_total = pcm.len / ch;
            const n = @min(frames_total - self.cursor_sample, n_frames - written);
            @memcpy(out[written * ch .. (written + n) * ch], pcm[self.cursor_sample * ch .. (self.cursor_sample + n) * ch]);
            written += n;
            self.cursor_sample += n;
            if (self.cursor_sample >= frames_total) {
                self.gap_left = (@as(usize, j.chunks[self.cursor_chunk].pause_after_ms) * self.sample_rate) / 1000;
                self.cursor_chunk += 1;
                self.cursor_sample = 0;
                self.chunk_announced = false;
            }
        }
        return written;
    }

    /// Start the audio queue if there is something to play. Never call with mu held.
    fn ensurePlaying(self: *Core) void {
        self.player_mu.lock();
        defer self.player_mu.unlock();
        const p = self.player orelse return;
        self.mu.lock();
        const active = self.current != null and !self.paused;
        self.mu.unlock();
        if (active) _ = c.ta_player_start(p);
    }

    // ------------------------------------------------------------ engine thread

    const Work = struct { job: *Job, index: usize, text: [:0]const u8, voice: [:0]const u8, speed: f32 };

    /// Pick the next chunk to synthesize (caller holds mu).
    fn pickWork(self: *Core, a: std.mem.Allocator) !?Work {
        const prefetch = 1;
        if (self.current) |j| {
            var i = self.cursor_chunk;
            while (i < j.chunks.len and i <= self.cursor_chunk + prefetch) : (i += 1) {
                if (j.audio[i] == null) return try self.makeWork(a, j, i);
            }
        }
        if (self.pending.items.len > 0) {
            const j = self.pending.items[0];
            if (j.audio[0] == null) return try self.makeWork(a, j, 0);
        }
        return null;
    }

    fn makeWork(self: *Core, a: std.mem.Allocator, j: *Job, i: usize) !Work {
        const voice = if (j.voice.len > 0) j.voice else self.resolveVoice();
        return .{
            .job = j,
            .index = i,
            .text = try a.dupeSentinel(u8, j.chunks[i].text, 0),
            .voice = try a.dupeSentinel(u8, voice, 0),
            // models without speed control reject anything but 1.0
            .speed = if (self.catalog.find(self.engine_model)) |m| (if (m.supports_speed) j.speed else 1.0) else j.speed,
        };
    }

    /// Settings voice if it belongs to the loaded model, else the model default.
    fn resolveVoice(self: *Core) []const u8 {
        const m = self.catalog.find(self.engine_model) orelse return "";
        if (self.settings.voice.len > 0) {
            for (self.voices.items) |v| {
                if (std.mem.eql(u8, v, self.settings.voice)) return self.settings.voice;
            }
        }
        return m.default_voice;
    }

    fn engineMain(self: *Core) void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        self.mu.lock();
        while (!self.shutting_down) {
            // free retired jobs (only this thread frees jobs, never mid-synthesis)
            for (self.graveyard.items) |j| self.freeJob(j);
            self.graveyard.clearRetainingCapacity();
            _ = scratch.reset(.retain_capacity);

            const wanted = self.settings.model;
            const busy = self.current != null or self.pending.items.len > 0;
            const model_mismatch = self.load_state == .loaded and !std.mem.eql(u8, self.engine_model, wanted);
            if (model_mismatch or ((busy or self.load_requested) and self.load_state != .loaded and self.load_state != .failed)) {
                self.loadModel(wanted); // drops and retakes mu
                continue;
            }
            if (self.load_state == .failed and busy) {
                // no usable model: fail everything rather than spin
                for (self.pending.items) |p| self.retire(p, .failed);
                self.pending.clearRetainingCapacity();
                if (self.current) |cur| {
                    self.current = null;
                    self.retire(cur, .failed);
                }
                continue;
            }

            const work = self.pickWork(scratch.allocator()) catch null;
            if (work) |w| {
                self.last_active_ms = self.nowMs();
                const engine = self.engine.?;
                self.mu.unlock();
                const pcm = synthesize(self.gpa, engine, w);
                self.mu.lock();
                // the job may be retired meanwhile; it is still allocated
                // (only this thread frees), so storing is safe
                w.job.audio[w.index] = pcm;
                const is_current = self.current == w.job;
                self.mu.unlock();
                if (is_current) self.ensurePlaying();
                self.mu.lock();
                continue;
            }

            // idle: pause the hardware after 2 s, unload after the configured time
            const now = self.nowMs();
            const idle = self.current == null or self.paused;
            if (!idle) self.last_active_ms = now;
            const unload_after: i64 = @as(i64, self.settings.idle_unload_minutes) * 60_000;
            if (idle and now - self.last_active_ms > 2000) {
                self.mu.unlock();
                self.pauseHardwareIfIdle();
                self.mu.lock();
            }
            if (self.current == null and self.pending.items.len == 0 and self.load_state == .loaded and
                unload_after > 0 and now - self.last_active_ms > unload_after and !self.load_requested)
            {
                self.unloadModel();
                continue;
            }
            self.work_cv.timedWait(&self.mu, 1000);
        }
        self.mu.unlock();
    }

    fn pauseHardwareIfIdle(self: *Core) void {
        self.player_mu.lock();
        defer self.player_mu.unlock();
        const p = self.player orelse return;
        if (c.ta_player_is_running(p) == 0) return;
        self.mu.lock();
        const idle = self.current == null or self.paused;
        self.mu.unlock();
        if (idle) _ = c.ta_player_pause(p);
    }

    fn synthesize(gpa: std.mem.Allocator, engine: *c.te_engine, w: Work) []f32 {
        const Collect = struct {
            gpa: std.mem.Allocator,
            buf: std.ArrayList(f32) = .empty,
            fn cb(user: ?*anyopaque, pcm: [*c]const f32, n: usize) callconv(.c) i32 {
                const s: *@This() = @ptrCast(@alignCast(user.?));
                s.buf.appendSlice(s.gpa, pcm[0..n]) catch return 1;
                return 0;
            }
        };
        var col: Collect = .{ .gpa = gpa };
        var sp = c.te_synth_params_default();
        sp.text = w.text.ptr;
        sp.voice = w.voice.ptr;
        sp.speed = w.speed;
        var err: [256]u8 = @splat(0);
        const rc = c.te_synthesize(engine, &sp, Collect.cb, &col, null, &err, err.len);
        if (rc != 0) {
            log.err("synthesis failed for chunk {d}: {s}", .{ w.index, std.mem.sliceTo(&err, 0) });
            col.buf.deinit(gpa);
            return &.{};
        }
        return col.buf.toOwnedSlice(gpa) catch &.{};
    }

    /// Caller holds mu; released during the load.
    fn loadModel(self: *Core, id: []const u8) void {
        if (self.engine != null) self.unloadModel();
        const m = self.catalog.find(id) orelse {
            self.failLoad("unknown model");
            return;
        };
        self.load_state = .loading;
        self.engine_model = m.id;
        self.pushEvent((Event{ .kind = .model_state }).withState("loading"));
        self.mu.unlock();

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var err: [256]u8 = @splat(0);
        var engine: ?*c.te_engine = null;
        if (models.localPaths(arena.allocator(), self.paths.models, m.*)) |lp| {
            if (!models.isInstalled(self.io, lp, m.*)) {
                _ = std.fmt.bufPrint(&err, "model {s} is not installed (talktome models download {s})", .{ m.id, m.id }) catch {};
            } else {
                var p = c.te_load_params_default();
                p.model_path = lp.model.ptr;
                p.mmproj_path = lp.mmproj.ptr;
                engine = c.te_load(&p, &err, err.len);
            }
        } else |_| {}

        var voices_ok = true;
        if (engine) |e| {
            _ = self.voices_arena.reset(.retain_capacity);
            self.voices = .empty;
            const va = self.voices_arena.allocator();
            var i: i32 = 0;
            while (c.te_voice_name(e, i)) |name| : (i += 1) {
                const v = va.dupe(u8, std.mem.span(name)) catch {
                    voices_ok = false;
                    break;
                };
                self.voices.append(va, v) catch {
                    voices_ok = false;
                    break;
                };
            }
            self.ensurePlayer(@intCast(c.te_sample_rate(e)), @intCast(@max(1, c.te_channels(e))));
        }

        self.mu.lock();
        self.load_requested = false;
        if (engine) |e| {
            self.engine = e;
            self.sample_rate = @intCast(c.te_sample_rate(e));
            self.channels = @intCast(@max(1, c.te_channels(e)));
            self.load_state = .loaded;
            self.pushEvent((Event{ .kind = .model_state }).withState("loaded"));
            log.info("loaded {s} ({d} voices, {d} Hz)", .{ m.id, self.voices.items.len, self.sample_rate });
        } else {
            self.failLoad(std.mem.sliceTo(&err, 0));
        }
        if (!voices_ok) log.warn("voice list truncated (out of memory)", .{});
        self.load_cv.broadcast();
    }

    fn failLoad(self: *Core, msg: []const u8) void {
        self.load_state = .failed;
        copyTrunc(&self.load_error, msg);
        self.pushEvent((Event{ .kind = .model_state }).withState("failed"));
        self.load_cv.broadcast();
        log.err("model load failed: {s}", .{msg});
    }

    /// Caller holds mu.
    fn unloadModel(self: *Core) void {
        if (self.engine) |e| {
            c.te_free(e);
            self.engine = null;
            log.info("unloaded {s}", .{self.engine_model});
        }
        self.load_state = .unloaded;
        self.voices = .empty;
        _ = self.voices_arena.reset(.retain_capacity);
        self.pushEvent((Event{ .kind = .model_state }).withState("unloaded"));
    }

    /// Create (or recreate for a new sample rate) the audio output. Called
    /// from the engine thread without mu.
    fn ensurePlayer(self: *Core, rate: u32, channels: u32) void {
        self.player_mu.lock();
        defer self.player_mu.unlock();
        if (self.player != null and self.player_rate == rate) return;
        if (self.player) |p| c.ta_player_free(p);
        // pull() reads sample_rate/channels under mu; set them first
        self.mu.lock();
        self.sample_rate = rate;
        self.channels = channels;
        self.mu.unlock();
        var status: i32 = 0;
        self.player = c.ta_player_create(@floatFromInt(rate), @intCast(channels), pullCb, self, &status);
        self.player_rate = rate;
        if (self.player == null) log.err("audio output failed (OSStatus {d})", .{status});
    }

    /// Ask the engine thread to load the active model and wait for it
    /// (voices listing). Returns false on failure or timeout.
    pub fn requireModel(self: *Core, timeout_ms: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.load_state == .failed) self.load_state = .unloaded; // retry
        const deadline = self.nowMs() + @as(i64, @intCast(timeout_ms));
        while (self.load_state != .loaded or !std.mem.eql(u8, self.engine_model, self.settings.model)) {
            if (self.load_state == .failed) return false;
            self.load_requested = true;
            self.work_cv.signal();
            const left = deadline - self.nowMs();
            if (left <= 0) return false;
            self.load_cv.timedWait(&self.mu, @intCast(left));
        }
        return true;
    }

    /// Clear a failed load so the next job retries (e.g. after a download).
    pub fn resetLoadFailure(self: *Core) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.load_state == .failed) self.load_state = .unloaded;
        self.work_cv.signal();
    }

    // ------------------------------------------------------------ downloads

    pub fn startDownload(self: *Core, id: []const u8) !void {
        const m = self.catalog.find(id) orelse return error.UnknownModel;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.download_progress.active.load(.acquire)) return error.DownloadInProgress;
        if (self.download_thread) |t| {
            t.join();
            self.download_thread = null;
        }
        self.download_model = m.id;
        self.download_progress = .{};
        self.download_progress.active.store(true, .release);
        @memset(&self.download_error, 0);
        self.download_thread = try std.Thread.spawn(.{}, downloadMain, .{ self, m });
    }

    pub fn cancelDownload(self: *Core) void {
        self.download_progress.cancel.store(true, .release);
    }

    fn downloadMain(self: *Core, m: *const models.Model) void {
        log.info("downloading {s} ({d} MB)", .{ m.id, m.totalSize() / 1_000_000 });
        models.download(self.gpa, self.io, self.paths.models, m.*, &self.download_progress) catch |err| {
            self.mu.lock();
            _ = std.fmt.bufPrint(&self.download_error, "{t}", .{err}) catch {};
            self.mu.unlock();
            log.err("download of {s} failed: {t}", .{ m.id, err });
        };
        self.download_progress.active.store(false, .release);
        self.resetLoadFailure();
        log.info("download of {s} finished", .{m.id});
    }

    // ------------------------------------------------------------ snapshots

    pub const PlayerSnapshot = struct {
        state: []const u8,
        job: ?u64,
        app: []const u8,
        label: []const u8,
        index: usize,
        count: usize,
        queued: usize,
        model: []const u8,
        model_state: []const u8,
        model_error: []const u8,
    };

    pub fn playerSnapshot(self: *Core, a: std.mem.Allocator) !PlayerSnapshot {
        self.mu.lock();
        defer self.mu.unlock();
        const cur = self.current;
        return .{
            .state = if (cur == null) "idle" else if (self.paused) "paused" else "playing",
            .job = if (cur) |j| j.id else null,
            .app = if (cur) |j| try a.dupe(u8, j.source.app) else "",
            .label = if (cur) |j| try a.dupe(u8, j.source.label) else "",
            .index = if (cur != null) self.cursor_chunk else 0,
            .count = if (cur) |j| j.chunks.len else 0,
            .queued = self.pending.items.len,
            .model = try a.dupe(u8, self.settings.model),
            .model_state = @tagName(self.load_state),
            .model_error = if (self.load_state == .failed) try a.dupe(u8, std.mem.sliceTo(&self.load_error, 0)) else "",
        };
    }

    pub const JobView = struct {
        id: u64,
        app: []const u8,
        label: []const u8,
        preview: []const u8,
        chunks: usize,
        state: JobState,
        index: ?usize = null,
        finished_ms: ?i64 = null,
        has_text: bool = true,
    };

    /// Current, pending, then recent history (newest first).
    pub fn jobViews(self: *Core, a: std.mem.Allocator) ![]JobView {
        self.mu.lock();
        defer self.mu.unlock();
        var out: std.ArrayList(JobView) = .empty;
        if (self.current) |j| try out.append(a, try view(a, j, .playing, self.cursor_chunk));
        for (self.pending.items) |j| try out.append(a, try view(a, j, .queued, null));
        var k: usize = 0;
        while (k < self.history_count) : (k += 1) {
            const idx = (self.history_head + history_len - 1 - k) % history_len;
            const s = &self.history[idx];
            try out.append(a, .{
                .id = s.id,
                .app = try a.dupe(u8, Summary.str(&s.app)),
                .label = try a.dupe(u8, Summary.str(&s.label)),
                .preview = try a.dupe(u8, Summary.str(&s.preview)),
                .chunks = s.chunks,
                .state = s.state,
                .finished_ms = s.finished_ms,
                .has_text = self.historyTextFor(s.id) != null,
            });
        }
        return out.items;
    }

    fn view(a: std.mem.Allocator, j: *const Job, state: JobState, index: ?usize) !JobView {
        return .{
            .id = j.id,
            .app = try a.dupe(u8, j.source.app),
            .label = try a.dupe(u8, j.source.label),
            .preview = try a.dupe(u8, j.preview),
            .chunks = j.chunks.len,
            .state = state,
            .index = index,
        };
    }

    pub const JobDetail = struct { view: JobView, text: []const u8 };

    /// One job (current, queued or in history) with its full text.
    pub fn jobDetail(self: *Core, a: std.mem.Allocator, id: u64) !?JobDetail {
        const views = try self.jobViews(a);
        self.mu.lock();
        defer self.mu.unlock();
        for (views) |v| {
            if (v.id != id) continue;
            if (self.current) |j| if (j.id == id) return .{ .view = v, .text = try jobText(a, j) };
            for (self.pending.items) |j| if (j.id == id) return .{ .view = v, .text = try jobText(a, j) };
            const text = self.historyTextFor(id) orelse return .{ .view = v, .text = "" };
            return .{ .view = v, .text = try a.dupe(u8, text) };
        }
        return null;
    }

    pub const ModelView = struct {
        id: []const u8,
        name: []const u8,
        description: []const u8,
        recommended: bool,
        size: u64,
        installed: bool,
        active: bool,
        loaded: bool,
        download: ?struct { done: u64, total: u64, active: bool, @"error": []const u8 } = null,
    };

    pub fn modelViews(self: *Core, a: std.mem.Allocator) ![]ModelView {
        var out: std.ArrayList(ModelView) = .empty;
        self.mu.lock();
        defer self.mu.unlock();
        for (self.catalog.all()) |m| {
            const lp = try models.localPaths(a, self.paths.models, m);
            var v: ModelView = .{
                .id = m.id,
                .name = m.name,
                .description = m.description,
                .recommended = m.recommended,
                .size = m.totalSize(),
                .installed = models.isInstalled(self.io, lp, m),
                .active = std.mem.eql(u8, m.id, self.settings.model),
                .loaded = self.load_state == .loaded and std.mem.eql(u8, m.id, self.engine_model),
            };
            if (std.mem.eql(u8, m.id, self.download_model)) {
                v.download = .{
                    .done = self.download_progress.done.load(.monotonic),
                    .total = self.download_progress.total.load(.monotonic),
                    .active = self.download_progress.active.load(.acquire),
                    .@"error" = try a.dupe(u8, std.mem.sliceTo(&self.download_error, 0)),
                };
            }
            try out.append(a, v);
        }
        return out.items;
    }

    /// Accent and gender from a voice name: Kokoro "af_heart" (a/b = US/UK,
    /// f/m), ZONOS3 "Savannah_en-American_F_1", tiny-voca "F2".
    fn voiceTags(v: []const u8) struct { accent: []const u8, gender: []const u8 } {
        if (std.mem.indexOf(u8, v, "_en-")) |i| {
            const rest = v[i + 4 ..];
            const accent: []const u8 = if (std.mem.startsWith(u8, rest, "American")) "US" else if (std.mem.startsWith(u8, rest, "British")) "UK" else "";
            const gender: []const u8 = if (std.mem.indexOf(u8, rest, "_F_") != null) "female" else if (std.mem.indexOf(u8, rest, "_M_") != null) "male" else "";
            return .{ .accent = accent, .gender = gender };
        }
        if (v.len > 2 and v[2] == '_') {
            const accent: []const u8 = if (v[0] == 'a') "US" else if (v[0] == 'b') "UK" else "";
            const gender: []const u8 = if (v[1] == 'f') "female" else if (v[1] == 'm') "male" else "";
            return .{ .accent = accent, .gender = gender };
        }
        if (v.len > 0 and v[0] == 'F') return .{ .accent = "", .gender = "female" };
        if (v.len > 0 and v[0] == 'M') return .{ .accent = "", .gender = "male" };
        return .{ .accent = "", .gender = "" };
    }

    pub const VoiceView = struct { name: []const u8, accent: []const u8, gender: []const u8, default: bool };

    /// English voices of the loaded active model. Call requireModel() first.
    pub fn voiceViews(self: *Core, a: std.mem.Allocator) ![]VoiceView {
        self.mu.lock();
        defer self.mu.unlock();
        const m = self.catalog.find(self.engine_model) orelse return &.{};
        var out: std.ArrayList(VoiceView) = .empty;
        const def = self.resolveVoice();
        for (self.voices.items) |v| {
            if (!m.isEnglishVoice(v)) continue;
            const tags = voiceTags(v);
            try out.append(a, .{
                .name = try a.dupe(u8, v),
                .accent = tags.accent,
                .gender = tags.gender,
                .default = std.mem.eql(u8, v, def),
            });
        }
        return out.items;
    }
};
