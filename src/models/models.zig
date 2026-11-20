//! Model catalog (embedded catalog.json) and the downloader.
//!
//! Files come from Hugging Face at a pinned revision:
//!   https://huggingface.co/<repo>/resolve/<revision>/<file>
//! They download to models/<id>/<file>.part with resume, are checked against
//! the catalog's sha256, then renamed into place. The transfer itself runs
//! /usr/bin/curl (redirects to the HF CDN, resume, retries); hashing, state
//! and progress stay here.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const File = struct {
    file: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    recommended: bool = false,
    pipeline: []const u8,
    repo: []const u8,
    revision: []const u8,
    model: File,
    mmproj: File,
    default_voice: []const u8,
    /// English voice filter (name prefixes); empty = all voices
    voice_prefixes: []const []const u8 = &.{},
    /// English voice filter (substrings, e.g. "_en-"); empty = no filter
    voice_contains: []const []const u8 = &.{},
    supports_speed: bool = true,

    pub fn totalSize(m: Model) u64 {
        return m.model.size + m.mmproj.size;
    }

    pub fn isEnglishVoice(m: Model, voice: []const u8) bool {
        if (m.voice_prefixes.len == 0 and m.voice_contains.len == 0) return true;
        for (m.voice_prefixes) |p| {
            if (std.mem.startsWith(u8, voice, p)) return true;
        }
        for (m.voice_contains) |c| {
            if (std.mem.indexOf(u8, voice, c) != null) return true;
        }
        return false;
    }
};

const CatalogFile = struct { models: []Model };

pub const Catalog = struct {
    parsed: std.json.Parsed(CatalogFile),

    pub fn load(gpa: std.mem.Allocator) !Catalog {
        const parsed = try std.json.parseFromSlice(CatalogFile, gpa, @embedFile("catalog.json"), .{
            .ignore_unknown_fields = true,
        });
        return .{ .parsed = parsed };
    }

    pub fn deinit(c: *Catalog) void {
        c.parsed.deinit();
    }

    pub fn all(c: *const Catalog) []const Model {
        return c.parsed.value.models;
    }

    pub fn find(c: *const Catalog, id: []const u8) ?*const Model {
        for (c.parsed.value.models) |*m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }
};

pub const LocalPaths = struct {
    dir: []const u8,
    model: [:0]const u8,
    mmproj: [:0]const u8,
};

pub fn localPaths(arena: std.mem.Allocator, models_root: []const u8, m: Model) !LocalPaths {
    const dir = try std.fs.path.join(arena, &.{ models_root, m.id });
    return .{
        .dir = dir,
        .model = try std.fs.path.joinZ(arena, &.{ dir, m.model.file }),
        .mmproj = try std.fs.path.joinZ(arena, &.{ dir, m.mmproj.file }),
    };
}

fn fileSize(io: Io, path: []const u8) ?u64 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.size;
}

/// Installed = both files present with the catalog size (hashes are checked
/// when downloading).
pub fn isInstalled(io: Io, lp: LocalPaths, m: Model) bool {
    return fileSize(io, lp.model) == m.model.size and fileSize(io, lp.mmproj) == m.mmproj.size;
}

pub fn sha256Hex(io: Io, path: []const u8, out: *[64]u8) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var r = file.reader(io, &buf);
    var h = Sha256.init(.{});
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        h.update(chunk);
        r.interface.toss(chunk.len);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    _ = try std.fmt.bufPrint(out, "{x}", .{&digest});
}

/// Progress of one download, shared with API readers (atomics only).
pub const Progress = struct {
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const DownloadError = error{ CurlFailed, HashMismatch, Cancelled } || anyerror;

/// Download every missing file of `m`. Blocking; call from a worker thread.
/// `progress.done` is updated from the .part file size while curl runs.
pub fn download(gpa: std.mem.Allocator, io: Io, models_root: []const u8, m: Model, progress: *Progress) DownloadError!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lp = try localPaths(arena, models_root, m);
    try Io.Dir.cwd().createDirPath(io, lp.dir);

    progress.total.store(m.totalSize(), .monotonic);
    var base: u64 = 0;
    for ([_]struct { f: File, path: []const u8 }{ .{ .f = m.model, .path = lp.model }, .{ .f = m.mmproj, .path = lp.mmproj } }) |item| {
        if (fileSize(io, item.path) == item.f.size) {
            base += item.f.size;
            progress.done.store(base, .monotonic);
            continue;
        }
        const part = try std.fmt.allocPrint(arena, "{s}.part", .{item.path});
        const url = try std.fmt.allocPrint(arena, "https://huggingface.co/{s}/resolve/{s}/{s}", .{ m.repo, m.revision, item.f.file });

        var child = try std.process.spawn(io, .{
            .argv = &.{ "/usr/bin/curl", "-fsSL", "--retry", "3", "-C", "-", "-o", part, url },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        // A poller thread reports the .part size and handles cancel (SIGTERM);
        // this thread blocks in wait() and reaps curl.
        var poll: Poller = .{ .io = io, .part = part, .base = base, .progress = progress, .pid = child.id.? };
        const poller = try std.Thread.spawn(.{}, Poller.run, .{&poll});
        const term = child.wait(io);
        poll.stop.store(true, .release);
        poller.join();
        if (progress.cancel.load(.monotonic)) return error.Cancelled;
        const t = term catch return error.CurlFailed;
        if (!t.success()) return error.CurlFailed;

        var hex: [64]u8 = undefined;
        try sha256Hex(io, part, &hex);
        if (!std.mem.eql(u8, &hex, item.f.sha256)) {
            Io.Dir.cwd().deleteFile(io, part) catch {};
            return error.HashMismatch;
        }
        try Io.Dir.rename(.cwd(), part, .cwd(), item.path, io);
        base += item.f.size;
        progress.done.store(base, .monotonic);
    }
}

const Poller = struct {
    io: Io,
    part: []const u8,
    base: u64,
    progress: *Progress,
    pid: std.process.Child.Id,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(p: *Poller) void {
        var signalled = false;
        while (!p.stop.load(.acquire)) {
            if (fileSize(p.io, p.part)) |s| p.progress.done.store(p.base + s, .monotonic);
            if (!signalled and p.progress.cancel.load(.monotonic)) {
                std.posix.kill(p.pid, std.posix.SIG.TERM) catch {};
                signalled = true;
            }
            p.io.sleep(.fromMilliseconds(250), .awake) catch {};
        }
    }
};

/// Remove a model's files.
pub fn remove(gpa: std.mem.Allocator, io: Io, models_root: []const u8, m: Model) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lp = try localPaths(arena_state.allocator(), models_root, m);
    try Io.Dir.cwd().deleteTree(io, lp.dir);
}
