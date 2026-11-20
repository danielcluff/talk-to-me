//! Local HTTP API on 127.0.0.1.
//!
//! Security: bound to loopback only; the Host header must name the loopback
//! address and port (DNS rebinding); every route except /v1/health needs
//! `Authorization: Bearer <token>`; requests carrying an Origin header are
//! rejected until the browser extension pairing exists (Phase 5), so web
//! pages cannot drive the API.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const core_mod = @import("core.zig");
const Core = core_mod.Core;
const config = @import("config.zig");

const log = std.log.scoped(.server);
pub const version = "0.1.0";

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    core: *Core,
    token: []const u8,
    port: u16,
    paths: config.Paths,
    /// `talktome serve` exits on POST /v1/shutdown so the app can take over
    /// the port; the app's in-process server ignores it.
    allow_shutdown: bool = false,
    pairing: Pairing = .{},
};

/// Browser extension pairing. An extension asks (POST /v1/pair, from an
/// extension Origin only); the app or CLI approves it; the extension then
/// collects the token once with its pairing secret.
const Pairing = struct {
    mu: Io.Mutex = .init,
    next_id: u32 = 1,
    items: [8]?Pair = @splat(null),

    const Pair = struct {
        id: u32,
        origin: [160]u8 = @splat(0),
        secret: [32]u8,
        code: [4]u8,
        status: enum { pending, approved, denied } = .pending,

        fn originStr(p: *const Pair) []const u8 {
            return std.mem.sliceTo(&p.origin, 0);
        }
    };
};

fn isExtensionOrigin(origin: []const u8) bool {
    return std.mem.startsWith(u8, origin, "chrome-extension://") or
        std.mem.startsWith(u8, origin, "moz-extension://") or
        std.mem.startsWith(u8, origin, "safari-web-extension://");
}

fn originPaired(s: *Server, a: std.mem.Allocator, origin: []const u8) bool {
    const settings = s.core.getSettings(a) catch return false;
    for (settings.paired_origins) |o| if (std.mem.eql(u8, o, origin)) return true;
    return false;
}

/// True if something accepts connections on the port.
pub fn portInUse(io: Io, port: u16) bool {
    const address = Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    const stream = address.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

/// Bind the API port. Callers check portInUse() first: reuse_address sets
/// SO_REUSEPORT too, which would let two live servers share the port, but it
/// is needed to rebind right after a previous server exits (TIME_WAIT).
pub fn listen(s: *Server) !Io.net.Server {
    if (portInUse(s.io, s.port)) return error.AddressInUse;
    const address = try Io.net.IpAddress.parse("127.0.0.1", s.port);
    return address.listen(s.io, .{ .reuse_address = true });
}

pub fn run(s: *Server) !void {
    var listener = try listen(s);
    defer listener.deinit(s.io);
    serveOn(s, &listener);
}

pub fn serveOn(s: *Server, listener: *Io.net.Server) void {
    log.info("listening on http://127.0.0.1:{d}", .{s.port});
    while (true) {
        const stream = listener.accept(s.io) catch |err| {
            log.err("accept failed: {t}", .{err});
            continue;
        };
        const t = std.Thread.spawn(.{}, connection, .{ s, stream }) catch |err| {
            log.err("thread spawn failed: {t}", .{err});
            stream.close(s.io);
            continue;
        };
        t.detach();
    }
}

fn connection(s: *Server, stream: Io.net.Stream) void {
    defer stream.close(s.io);
    var recv_buf: [8192]u8 = undefined;
    var send_buf: [8192]u8 = undefined;
    var reader = stream.reader(s.io, &recv_buf);
    var writer = stream.writer(s.io, &send_buf);
    var server = http.Server.init(&reader.interface, &writer.interface);
    while (server.reader.state == .ready) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return,
        };
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        handle(s, &req, arena.allocator()) catch |err| {
            log.debug("request failed: {t}", .{err});
            return;
        };
    }
}

const Head = struct {
    host: []const u8 = "",
    auth: []const u8 = "",
    origin: ?[]const u8 = null,
};

fn readHead(a: std.mem.Allocator, req: *http.Server.Request) !Head {
    var h: Head = .{};
    var it = req.iterateHeaders();
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "host")) h.host = try a.dupe(u8, hdr.value);
        if (std.ascii.eqlIgnoreCase(hdr.name, "authorization")) h.auth = try a.dupe(u8, hdr.value);
        if (std.ascii.eqlIgnoreCase(hdr.name, "origin")) h.origin = try a.dupe(u8, hdr.value);
    }
    return h;
}

fn hostAllowed(s: *Server, host: []const u8) bool {
    var buf: [64]u8 = undefined;
    const a = std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{s.port}) catch return false;
    if (std.mem.eql(u8, host, a)) return true;
    var buf2: [64]u8 = undefined;
    const b = std.fmt.bufPrint(&buf2, "localhost:{d}", .{s.port}) catch return false;
    return std.mem.eql(u8, host, b);
}

fn tokenOk(s: *Server, auth: []const u8) bool {
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth, prefix)) return false;
    const given = auth[prefix.len..];
    if (given.len != s.token.len) return false;
    var diff: u8 = 0;
    for (given, s.token) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// One API call, transport-independent: the request body in, status and JSON
/// out. The HTTP server and the in-process C interface (lib.zig) both use it.
pub const Exchange = struct {
    body: []const u8 = "",
    status: http.Status = .ok,
    reply: []const u8 = "{}",

    fn bodyLimited(ex: *Exchange, limit: usize) ![]const u8 {
        if (ex.body.len > limit) return error.BodyTooLarge;
        return ex.body;
    }
};

fn sendJson(ex: *Exchange, a: std.mem.Allocator, status: http.Status, value: anytype) !void {
    ex.status = status;
    ex.reply = try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
}

fn sendError(ex: *Exchange, a: std.mem.Allocator, status: http.Status, msg: []const u8) !void {
    try sendJson(ex, a, status, .{ .@"error" = msg });
}

fn respondError(req: *http.Server.Request, a: std.mem.Allocator, status: http.Status, msg: []const u8) !void {
    const body = try std.json.Stringify.valueAlloc(a, .{ .@"error" = msg }, .{});
    try req.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn readBody(req: *http.Server.Request, a: std.mem.Allocator, limit: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    const r = req.readerExpectNone(&buf);
    return r.allocRemaining(a, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => error.BodyTooLarge,
        else => err,
    };
}

fn handle(s: *Server, req: *http.Server.Request, a: std.mem.Allocator) !void {
    const method = req.head.method;
    const target = try a.dupe(u8, req.head.target);
    const head = try readHead(a, req);
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    if (!hostAllowed(s, head.host)) return respondError(req, a, .forbidden, "bad host");

    // pairing: an extension asks, then polls with its secret (no token yet)
    if (method == .POST and std.mem.eql(u8, path, "/v1/pair")) return pairRequest(s, req, a, head.origin);
    if (method == .GET and std.mem.startsWith(u8, path, "/v1/pair/") and std.mem.indexOfScalar(u8, path["/v1/pair/".len..], '/') == null) {
        return pairStatus(s, req, a, path["/v1/pair/".len..], target);
    }

    // web pages never get in; a paired extension does, with the token
    if (head.origin) |origin| {
        if (!isExtensionOrigin(origin) or !originPaired(s, a, origin)) {
            return respondError(req, a, .forbidden, "this origin is not paired with Talk to Me");
        }
        // approving a pairing is for the app and the CLI only
        if (std.mem.startsWith(u8, path, "/v1/pair")) return respondError(req, a, .forbidden, "not allowed from a browser");
    }
    const public = method == .GET and std.mem.eql(u8, path, "/v1/health");
    if (!public and !tokenOk(s, head.auth)) return respondError(req, a, .unauthorized, "missing or bad token");
    if (method == .GET and std.mem.eql(u8, path, "/v1/events")) return events(s, req, a);

    var ex: Exchange = .{};
    // only read a body the request declares (Content-Length or chunked); a
    // bare POST like /v1/player/stop would otherwise wait for EOF forever
    const declared = req.head.content_length != null or req.head.transfer_encoding == .chunked;
    if (method.requestHasBody() and declared) {
        ex.body = readBody(req, a, 4 << 20) catch return respondError(req, a, .payload_too_large, "body too large");
    }
    try dispatch(s, &ex, a, method, path);
    try req.respond(ex.reply, .{
        .status = ex.status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// Route one authenticated API call (everything except /v1/events and the
/// transport checks).
pub fn dispatch(s: *Server, ex: *Exchange, a: std.mem.Allocator, method: http.Method, path: []const u8) !void {
    const req = ex;
    if (method == .GET and std.mem.eql(u8, path, "/v1/health")) {
        const p = try s.core.playerSnapshot(a);
        return sendJson(req, a, .ok, .{ .ok = true, .version = version, .model = p.model, .model_state = p.model_state, .queued = p.queued, .state = p.state });
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/shutdown")) {
        if (!s.allow_shutdown) return sendError(req, a, .forbidden, "this server is hosted by the app");
        const t = try std.Thread.spawn(.{}, struct {
            fn run(io: Io) void {
                io.sleep(.fromMilliseconds(200), .awake) catch {};
                std.process.exit(0);
            }
        }.run, .{s.io});
        t.detach();
        return sendJson(req, a, .ok, .{ .ok = true });
    }
    if (std.mem.startsWith(u8, path, "/v1/pair")) return pairAdmin(s, req, a, method, path);
    if (std.mem.startsWith(u8, path, "/v1/briefing/")) return briefingRoute(s, req, a, method, path["/v1/briefing/".len..]);
    if (method == .POST and std.mem.eql(u8, path, "/v1/speak")) return speak(s, req, a);
    if (method == .POST and std.mem.eql(u8, path, "/v1/speak/file")) return speakFile(s, req, a);
    if (method == .GET and std.mem.eql(u8, path, "/v1/jobs")) return sendJson(req, a, .ok, .{ .jobs = try s.core.jobViews(a) });
    if (std.mem.startsWith(u8, path, "/v1/jobs/") and (method == .GET or method == .POST)) return jobRoute(s, req, a, method, path["/v1/jobs/".len..]);
    if (method == .DELETE and std.mem.startsWith(u8, path, "/v1/jobs/")) {
        const id = parseJobId(path["/v1/jobs/".len..]) orelse return sendError(req, a, .bad_request, "bad job id");
        if (!s.core.removeJob(id)) return sendError(req, a, .not_found, "no such job");
        return sendJson(req, a, .ok, .{ .ok = true });
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/player")) return sendJson(req, a, .ok, try s.core.playerSnapshot(a));
    if (method == .POST and std.mem.startsWith(u8, path, "/v1/player/")) {
        const cmd = std.meta.stringToEnum(Core.Command, path["/v1/player/".len..]) orelse
            return sendError(req, a, .not_found, "unknown player command");
        s.core.command(cmd);
        return sendJson(req, a, .ok, try s.core.playerSnapshot(a));
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/models")) return sendJson(req, a, .ok, .{ .models = try s.core.modelViews(a) });
    if (std.mem.startsWith(u8, path, "/v1/models/")) return modelRoute(s, req, a, method, path["/v1/models/".len..]);
    if (method == .GET and std.mem.eql(u8, path, "/v1/voices")) {
        if (!s.core.requireModel(60_000)) {
            const p = try s.core.playerSnapshot(a);
            return sendError(req, a, .service_unavailable, if (p.model_error.len > 0) p.model_error else "model not loaded");
        }
        const settings = try s.core.getSettings(a);
        return sendJson(req, a, .ok, .{ .model = settings.model, .voices = try s.core.voiceViews(a) });
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/settings")) return sendJson(req, a, .ok, try s.core.getSettings(a));
    if (method == .PATCH and std.mem.eql(u8, path, "/v1/settings")) return patchSettings(s, req, a);
    return sendError(req, a, .not_found, "not found");
}

/// POST /v1/briefing/answer {"answer": "yes"|"no"}: answer "Want the full report?"
/// POST /v1/briefing/last: read the full report behind the latest briefing.
/// POST /v1/briefing/test {"text"?}: brief a sample report now (Settings → Test).
/// GET  /v1/briefing/status: whether a question is waiting for an answer.
fn briefingRoute(s: *Server, req: *Exchange, a: std.mem.Allocator, method: http.Method, action: []const u8) !void {
    if (method == .GET and std.mem.eql(u8, action, "status")) {
        return sendJson(req, a, .ok, .{ .awaiting_answer = s.core.awaitingAnswer() });
    }
    if (method != .POST) return sendError(req, a, .not_found, "not found");
    if (std.mem.eql(u8, action, "answer")) {
        const B = struct { answer: []const u8 = "" };
        const b = std.json.parseFromSliceLeaky(B, a, req.body, .{ .ignore_unknown_fields = true }) catch B{};
        const yes = std.ascii.eqlIgnoreCase(b.answer, "yes");
        if (!yes and !std.ascii.eqlIgnoreCase(b.answer, "no")) return sendError(req, a, .bad_request, "answer must be yes or no");
        const r = try s.core.answer(yes);
        return sendJson(req, a, if (r == .no_question) .conflict else .ok, .{ .result = @tagName(r) });
    }
    if (std.mem.eql(u8, action, "last")) {
        if (!try s.core.readLastReport()) return sendError(req, a, .not_found, "no report yet");
        return sendJson(req, a, .ok, .{ .ok = true });
    }
    if (std.mem.eql(u8, action, "test")) {
        const B = struct { text: ?[]const u8 = null };
        const b = std.json.parseFromSliceLeaky(B, a, req.body, .{ .ignore_unknown_fields = true }) catch B{};
        const sample =
            \\I refactored the markdown parser so headings, lists and links are read naturally, and code blocks are announced instead of read.
            \\
            \\All 18 unit tests pass, and I added four new ones for the pronunciation dictionary. The build is clean.
            \\
            \\One thing needs you: the History page keeps 50 items. Should I make that a setting, or keep the fixed limit?
        ;
        const result = try s.core.speak(.{
            .kind = .reply,
            .force_brief = true,
            .text = b.text orelse sample,
            .source = .{ .app = "codex", .label = "a sample report" },
            .policy = .interrupt,
        });
        return respondSpeak(req, a, result);
    }
    return sendError(req, a, .not_found, "not found");
}

/// GET /v1/jobs/{id}: the job with its full text.
/// POST /v1/jobs/{id}/replay: speak it again now, in its source's voice.
fn jobRoute(s: *Server, req: *Exchange, a: std.mem.Allocator, method: http.Method, rest: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const id = parseJobId(if (slash) |i| rest[0..i] else rest) orelse return sendError(req, a, .bad_request, "bad job id");
    const action = if (slash) |i| rest[i + 1 ..] else "";
    const d = (try s.core.jobDetail(a, id)) orelse return sendError(req, a, .not_found, "no such job");
    if (method == .GET and action.len == 0) {
        return sendJson(req, a, .ok, .{ .job = d.view, .text = d.text });
    }
    if (method == .POST and std.mem.eql(u8, action, "replay")) {
        if (d.text.len == 0) return sendError(req, a, .gone, "the text of this item is no longer kept");
        const settings = try s.core.getSettings(a);
        const voice: ?[]const u8 = if (settings.sources.map.get(d.view.app)) |ss| (if (ss.voice.len > 0) ss.voice else null) else null;
        const label = if (d.view.label.len > 0)
            try std.fmt.allocPrint(a, "{s} · {s}", .{ config.sourceName(d.view.app), d.view.label })
        else
            config.sourceName(d.view.app);
        const result = try s.core.speak(.{
            .text = d.text,
            .format = .text,
            .source = .{ .app = "history", .label = label },
            .voice = voice,
            .policy = .interrupt,
        });
        return respondSpeak(req, a, result);
    }
    return sendError(req, a, .not_found, "not found");
}

pub fn parseJobId(text: []const u8) ?u64 {
    const t = if (std.mem.startsWith(u8, text, "j_")) text[2..] else text;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

fn jobIdStr(a: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "j_{d}", .{id});
}

const SpeakBody = struct {
    kind: core_mod.Kind = .read,
    text: ?[]const u8 = null,
    chunks: ?[]const []const u8 = null,
    format: core_mod.Format = .markdown,
    source: core_mod.Source = .{},
    voice: ?[]const u8 = null,
    speed: ?f32 = null,
    policy: core_mod.Policy = .queue,
};

fn respondSpeak(req: *Exchange, a: std.mem.Allocator, result: core_mod.SpeakResult) !void {
    switch (result) {
        .queued => |q| try sendJson(req, a, .accepted, .{ .job_id = try jobIdStr(a, q.id), .chunks = q.chunks, .position = q.position }),
        .dropped => |reason| try sendJson(req, a, .ok, .{ .dropped = reason }),
        .summarizing => try sendJson(req, a, .accepted, .{ .summarizing = true }),
    }
}

fn speak(s: *Server, req: *Exchange, a: std.mem.Allocator) !void {
    const body = req.bodyLimited(4 << 20) catch return sendError(req, a, .payload_too_large, "body too large");
    const parsed = std.json.parseFromSliceLeaky(SpeakBody, a, body, .{ .ignore_unknown_fields = true }) catch
        return sendError(req, a, .bad_request, "invalid JSON body");
    if (parsed.text == null and parsed.chunks == null) return sendError(req, a, .bad_request, "text or chunks required");
    if (parsed.speed) |sp| if (!(sp >= 0.25 and sp <= 4.0)) return sendError(req, a, .bad_request, "speed must be 0.25-4");
    // briefing and report are internal kinds
    const kind: core_mod.Kind = switch (parsed.kind) {
        .briefing, .report => .read,
        else => parsed.kind,
    };
    const result = s.core.speak(.{
        .kind = kind,
        .text = parsed.text,
        .chunks = parsed.chunks,
        .format = parsed.format,
        .source = parsed.source,
        .voice = parsed.voice,
        .speed = parsed.speed,
        .policy = parsed.policy,
    }) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
    return respondSpeak(req, a, result);
}

const FileBody = struct {
    path: []const u8,
    voice: ?[]const u8 = null,
    speed: ?f32 = null,
    policy: core_mod.Policy = .interrupt,
    source: core_mod.Source = .{ .app = "file" },
};

pub const max_file_bytes = 2 << 20;

pub fn formatForPath(path: []const u8) ?core_mod.Format {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown")) return .markdown;
    if (std.ascii.eqlIgnoreCase(ext, ".txt") or std.ascii.eqlIgnoreCase(ext, ".text")) return .text;
    return null;
}

fn speakFile(s: *Server, req: *Exchange, a: std.mem.Allocator) !void {
    const body = req.bodyLimited(64 << 10) catch return sendError(req, a, .payload_too_large, "body too large");
    const parsed = std.json.parseFromSliceLeaky(FileBody, a, body, .{ .ignore_unknown_fields = true }) catch
        return sendError(req, a, .bad_request, "invalid JSON body");
    if (!std.fs.path.isAbsolute(parsed.path)) return sendError(req, a, .bad_request, "path must be absolute");
    const format = formatForPath(parsed.path) orelse return sendError(req, a, .bad_request, "only .md, .markdown and .txt files");
    const text = Io.Dir.cwd().readFileAlloc(s.io, parsed.path, a, .limited(max_file_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return sendError(req, a, .payload_too_large, "file larger than 2 MB"),
        error.FileNotFound => return sendError(req, a, .not_found, "file not found"),
        else => return sendError(req, a, .bad_request, @errorName(err)),
    };
    var source = parsed.source;
    if (source.label.len == 0) source.label = std.fs.path.basename(parsed.path);
    const result = s.core.speak(.{
        .text = text,
        .format = format,
        .source = source,
        .voice = parsed.voice,
        .speed = parsed.speed,
        .policy = parsed.policy,
    }) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
    return respondSpeak(req, a, result);
}

fn modelRoute(s: *Server, req: *Exchange, a: std.mem.Allocator, method: http.Method, rest: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const id = if (slash) |i| rest[0..i] else rest;
    const action = if (slash) |i| rest[i + 1 ..] else "";
    const m = s.core.catalog.find(id) orelse return sendError(req, a, .not_found, "unknown model");
    if (method == .POST and std.mem.eql(u8, action, "download")) {
        s.core.startDownload(m.id) catch |err| return sendError(req, a, .conflict, @errorName(err));
        return sendJson(req, a, .accepted, .{ .ok = true, .model = m.id });
    }
    if (method == .POST and std.mem.eql(u8, action, "cancel")) {
        s.core.cancelDownload();
        return sendJson(req, a, .ok, .{ .ok = true });
    }
    if (method == .POST and std.mem.eql(u8, action, "activate")) {
        var settings = try s.core.getSettings(a);
        if (!std.mem.eql(u8, m.id, settings.model)) settings.voice = "";
        settings.model = m.id;
        s.core.setSettings(settings) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
        return sendJson(req, a, .ok, .{ .ok = true, .model = m.id });
    }
    if (method == .DELETE and action.len == 0) {
        @import("models/models.zig").remove(s.gpa, s.io, s.paths.models, m.*) catch |err|
            return sendError(req, a, .internal_server_error, @errorName(err));
        s.core.resetLoadFailure();
        return sendJson(req, a, .ok, .{ .ok = true });
    }
    return sendError(req, a, .not_found, "not found");
}

const SettingsPatch = struct {
    model: ?[]const u8 = null,
    voice: ?[]const u8 = null,
    speed: ?f32 = null,
    idle_unload_minutes: ?u32 = null,
    code_blocks: ?@import("text/markdown.zig").CodeBlocks = null,
    tables: ?@import("text/markdown.zig").Tables = null,
    dedupe_seconds: ?u32 = null,
    /// replaces the whole list
    dictionary: ?[]const config.DictionaryEntry = null,
    briefing: ?BriefingPatch = null,
    /// merged per source: {"sources": {"codex": {"voice": "am_michael"}}}
    sources: ?std.json.ArrayHashMap(SourcePatch) = null,
};

const SourcePatch = struct {
    enabled: ?bool = null,
    voice: ?[]const u8 = null,
    announce: ?bool = null,
    brief: ?bool = null,
};

const BriefingPatch = struct {
    enabled: ?bool = null,
    backend: ?@import("briefing.zig").Backend = null,
    model: ?[]const u8 = null,
    ollama_url: ?[]const u8 = null,
    min_words: ?u32 = null,
    timeout_seconds: ?u32 = null,
    listen: ?bool = null,
    listen_seconds: ?u32 = null,
    recognizer: ?[]const u8 = null,
    yes_words: ?[]const []const u8 = null,
    no_words: ?[]const []const u8 = null,
};

fn patchSettings(s: *Server, req: *Exchange, a: std.mem.Allocator) !void {
    const body = req.bodyLimited(64 << 10) catch return sendError(req, a, .payload_too_large, "body too large");
    const patch = std.json.parseFromSliceLeaky(SettingsPatch, a, body, .{ .ignore_unknown_fields = false }) catch
        return sendError(req, a, .bad_request, "invalid settings (unknown key or bad value)");
    var settings = try s.core.getSettings(a);
    if (patch.model) |m| {
        if (s.core.catalog.find(m) == null) return sendError(req, a, .bad_request, "unknown model");
        if (!std.mem.eql(u8, m, settings.model)) settings.voice = "";
        settings.model = m;
    }
    if (patch.voice) |v| settings.voice = v;
    if (patch.speed) |sp| {
        if (!(sp >= 0.25 and sp <= 4.0)) return sendError(req, a, .bad_request, "speed must be 0.25-4");
        settings.speed = sp;
    }
    if (patch.idle_unload_minutes) |v| settings.idle_unload_minutes = v;
    if (patch.code_blocks) |v| settings.code_blocks = v;
    if (patch.tables) |v| settings.tables = v;
    if (patch.dedupe_seconds) |v| settings.dedupe_seconds = v;
    if (patch.dictionary) |d| settings.dictionary = d;
    if (patch.briefing) |b| {
        var cur = &settings.briefing;
        if (b.enabled) |v| cur.enabled = v;
        if (b.backend) |v| cur.backend = v;
        if (b.model) |v| cur.model = v;
        if (b.ollama_url) |v| cur.ollama_url = v;
        if (b.min_words) |v| cur.min_words = v;
        if (b.timeout_seconds) |v| cur.timeout_seconds = @max(v, 3);
        if (b.listen) |v| cur.listen = v;
        if (b.listen_seconds) |v| cur.listen_seconds = std.math.clamp(v, 2, 8);
        if (b.recognizer) |v| cur.recognizer = v;
        if (b.yes_words) |v| cur.yes_words = v;
        if (b.no_words) |v| cur.no_words = v;
    }
    if (patch.sources) |sp| {
        var it = sp.map.iterator();
        while (it.next()) |e| {
            var cur = settings.sources.map.get(e.key_ptr.*) orelse config.SourceSettings{};
            if (e.value_ptr.enabled) |v| cur.enabled = v;
            if (e.value_ptr.voice) |v| cur.voice = v;
            if (e.value_ptr.announce) |v| cur.announce = v;
            if (e.value_ptr.brief) |v| cur.brief = v;
            try settings.sources.map.put(a, e.key_ptr.*, cur);
        }
    }
    s.core.setSettings(settings) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
    return sendJson(req, a, .ok, try s.core.getSettings(a));
}

// ------------------------------------------------------------------ pairing

fn pairRequest(s: *Server, req: *http.Server.Request, a: std.mem.Allocator, origin: ?[]const u8) !void {
    const o = origin orelse return respondError(req, a, .forbidden, "pairing needs an extension Origin");
    if (!isExtensionOrigin(o) or o.len >= 160) return respondError(req, a, .forbidden, "only browser extensions can pair");
    var p: Pairing.Pair = .{ .id = 0, .secret = undefined, .code = undefined };
    var raw: [16]u8 = undefined;
    s.io.random(&raw);
    _ = std.fmt.bufPrint(&p.secret, "{x}", .{&raw}) catch unreachable;
    var n: [2]u8 = undefined;
    s.io.random(&n);
    _ = std.fmt.bufPrint(&p.code, "{d:0>4}", .{std.mem.readInt(u16, &n, .little) % 10000}) catch unreachable;
    @memcpy(p.origin[0..o.len], o);

    s.pairing.mu.lockUncancelable(s.io);
    p.id = s.pairing.next_id;
    s.pairing.next_id += 1;
    // keep the newest 8 requests
    var slot: usize = 0;
    var oldest: u32 = std.math.maxInt(u32);
    for (s.pairing.items, 0..) |it, i| {
        if (it == null) {
            slot = i;
            break;
        }
        if (it.?.id < oldest) {
            oldest = it.?.id;
            slot = i;
        }
    }
    s.pairing.items[slot] = p;
    s.pairing.mu.unlock(s.io);

    s.core.emit(core_mod.Core.eventWithState(.pair_request, p.id, &p.code));
    const body = try std.json.Stringify.valueAlloc(a, .{ .pair_id = p.id, .secret = &p.secret, .code = &p.code }, .{});
    try req.respond(body, .{ .status = .accepted, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

/// GET /v1/pair/{id}?secret=... : status, and the token once approved.
fn pairStatus(s: *Server, req: *http.Server.Request, a: std.mem.Allocator, id_text: []const u8, target: []const u8) !void {
    const id = std.fmt.parseInt(u32, id_text, 10) catch return respondError(req, a, .bad_request, "bad pairing id");
    const q = std.mem.indexOf(u8, target, "secret=") orelse return respondError(req, a, .unauthorized, "secret required");
    var secret = target[q + "secret=".len ..];
    if (std.mem.indexOfScalar(u8, secret, '&')) |amp| secret = secret[0..amp];

    s.pairing.mu.lockUncancelable(s.io);
    var status: []const u8 = "unknown";
    var token: ?[]const u8 = null;
    for (&s.pairing.items) |*slot| {
        const p = &(slot.* orelse continue);
        if (p.id != id or !std.mem.eql(u8, &p.secret, secret)) continue;
        switch (p.status) {
            .pending => status = "pending",
            .denied => {
                status = "denied";
                slot.* = null;
            },
            .approved => {
                status = "approved";
                token = s.token;
                slot.* = null; // the token is handed out once
            },
        }
        break;
    }
    s.pairing.mu.unlock(s.io);
    const body = try std.json.Stringify.valueAlloc(a, .{ .status = status, .token = token }, .{ .emit_null_optional_fields = false });
    try req.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

/// Authenticated (app, CLI): GET /v1/pair (pending + paired),
/// POST /v1/pair/{id}/approve|deny, POST /v1/pair/forget {"origin": ...}.
fn pairAdmin(s: *Server, req: *Exchange, a: std.mem.Allocator, method: http.Method, path: []const u8) !void {
    if (method == .GET and std.mem.eql(u8, path, "/v1/pair")) {
        const Pending = struct { id: u32, origin: []const u8, code: []const u8 };
        var pending: std.ArrayList(Pending) = .empty;
        s.pairing.mu.lockUncancelable(s.io);
        for (&s.pairing.items) |*slot| if (slot.*) |*p| if (p.status == .pending) {
            try pending.append(a, .{ .id = p.id, .origin = try a.dupe(u8, p.originStr()), .code = try a.dupe(u8, &p.code) });
        };
        s.pairing.mu.unlock(s.io);
        const settings = try s.core.getSettings(a);
        return sendJson(req, a, .ok, .{ .pending = pending.items, .paired = settings.paired_origins });
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/pair/forget")) {
        const F = struct { origin: []const u8 };
        const f = std.json.parseFromSliceLeaky(F, a, req.body, .{ .ignore_unknown_fields = true }) catch
            return sendError(req, a, .bad_request, "origin required");
        var settings = try s.core.getSettings(a);
        var keep: std.ArrayList([]const u8) = .empty;
        for (settings.paired_origins) |o| if (!std.mem.eql(u8, o, f.origin)) try keep.append(a, o);
        settings.paired_origins = keep.items;
        try s.core.setSettings(settings);
        return sendJson(req, a, .ok, .{ .ok = true });
    }
    if (method == .POST and std.mem.startsWith(u8, path, "/v1/pair/")) {
        const rest = path["/v1/pair/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return sendError(req, a, .not_found, "not found");
        const id = std.fmt.parseInt(u32, rest[0..slash], 10) catch return sendError(req, a, .bad_request, "bad pairing id");
        const approve = std.mem.eql(u8, rest[slash + 1 ..], "approve");
        if (!approve and !std.mem.eql(u8, rest[slash + 1 ..], "deny")) return sendError(req, a, .not_found, "not found");

        var origin: ?[]const u8 = null;
        s.pairing.mu.lockUncancelable(s.io);
        for (&s.pairing.items) |*slot| if (slot.*) |*p| if (p.id == id and p.status == .pending) {
            p.status = if (approve) .approved else .denied;
            origin = try a.dupe(u8, p.originStr());
        };
        s.pairing.mu.unlock(s.io);
        const o = origin orelse return sendError(req, a, .not_found, "no pending pairing with that id");
        if (approve) {
            var settings = try s.core.getSettings(a);
            const already = for (settings.paired_origins) |x| {
                if (std.mem.eql(u8, x, o)) break true;
            } else false;
            if (!already) {
                const list = try a.alloc([]const u8, settings.paired_origins.len + 1);
                @memcpy(list[0..settings.paired_origins.len], settings.paired_origins);
                list[list.len - 1] = o;
                settings.paired_origins = list;
                try s.core.setSettings(settings);
            }
        }
        return sendJson(req, a, .ok, .{ .ok = true, .origin = o, .approved = approve });
    }
    return sendError(req, a, .not_found, "not found");
}

/// One event as JSON; the same shape for SSE and the C interface.
pub fn eventJson(a: std.mem.Allocator, e: *const core_mod.Event) ![]const u8 {
    const job = if (e.job != 0) try jobIdStr(a, e.job) else null;
    return std.json.Stringify.valueAlloc(a, .{
        .seq = e.seq,
        .type = @tagName(e.kind),
        .job = job,
        .index = e.index,
        .count = e.count,
        .state = e.stateStr(),
    }, .{ .emit_null_optional_fields = false });
}

/// Server-sent events: one `data:` JSON line per event, plus a comment ping
/// every 15 s so dead connections are noticed.
fn events(s: *Server, req: *http.Server.Request, a: std.mem.Allocator) !void {
    var send_buf: [4096]u8 = undefined;
    var body = try req.respondStreaming(&send_buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    });
    var after = s.core.currentSeq();
    var batch: [64]core_mod.Event = undefined;
    var since_ping: u64 = 0;
    try body.writer.writeAll(": connected\n\n");
    try body.writer.flush(); // drain into the chunked stream
    try body.flush(); // then push the socket buffer
    while (true) {
        const n = s.core.waitEvents(after, &batch, 5000);
        if (n == 0) {
            since_ping += 5;
            if (since_ping >= 15) {
                try body.writer.writeAll(": ping\n\n");
                try body.writer.flush(); // drain into the chunked stream
                try body.flush(); // then push the socket buffer
                since_ping = 0;
            }
            continue;
        }
        for (batch[0..n]) |*e| {
            after = e.seq;
            const json = try eventJson(a, e);
            try body.writer.print("event: {s}\ndata: {s}\n\n", .{ @tagName(e.kind), json });
        }
        try body.writer.flush(); // drain into the chunked stream
        try body.flush(); // then push the socket buffer
    }
}
