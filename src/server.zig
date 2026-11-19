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
};

pub fn run(s: *Server) !void {
    const address = try Io.net.IpAddress.parse("127.0.0.1", s.port);
    var listener = try address.listen(s.io, .{ .reuse_address = true });
    defer listener.deinit(s.io);
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

fn sendJson(req: *http.Server.Request, a: std.mem.Allocator, status: http.Status, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
    try req.respond(body, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn sendError(req: *http.Server.Request, a: std.mem.Allocator, status: http.Status, msg: []const u8) !void {
    try sendJson(req, a, status, .{ .@"error" = msg });
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

    if (!hostAllowed(s, head.host)) return sendError(req, a, .forbidden, "bad host");
    if (head.origin != null) return sendError(req, a, .forbidden, "browser origins are not allowed yet");

    if (method == .GET and std.mem.eql(u8, path, "/v1/health")) {
        const p = try s.core.playerSnapshot(a);
        return sendJson(req, a, .ok, .{ .ok = true, .version = version, .model = p.model, .model_state = p.model_state, .queued = p.queued, .state = p.state });
    }
    if (!tokenOk(s, head.auth)) return sendError(req, a, .unauthorized, "missing or bad token");

    if (method == .POST and std.mem.eql(u8, path, "/v1/speak")) return speak(s, req, a);
    if (method == .POST and std.mem.eql(u8, path, "/v1/speak/file")) return speakFile(s, req, a);
    if (method == .GET and std.mem.eql(u8, path, "/v1/jobs")) return sendJson(req, a, .ok, .{ .jobs = try s.core.jobViews(a) });
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
    if (method == .GET and std.mem.eql(u8, path, "/v1/events")) return events(s, req, a);
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

pub fn parseJobId(text: []const u8) ?u64 {
    const t = if (std.mem.startsWith(u8, text, "j_")) text[2..] else text;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

fn jobIdStr(a: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "j_{d}", .{id});
}

const SpeakBody = struct {
    text: ?[]const u8 = null,
    chunks: ?[]const []const u8 = null,
    format: core_mod.Format = .markdown,
    source: core_mod.Source = .{},
    voice: ?[]const u8 = null,
    speed: ?f32 = null,
    policy: core_mod.Policy = .queue,
};

fn respondSpeak(req: *http.Server.Request, a: std.mem.Allocator, result: core_mod.SpeakResult) !void {
    switch (result) {
        .queued => |q| try sendJson(req, a, .accepted, .{ .job_id = try jobIdStr(a, q.id), .chunks = q.chunks, .position = q.position }),
        .dropped => |reason| try sendJson(req, a, .ok, .{ .dropped = reason }),
    }
}

fn speak(s: *Server, req: *http.Server.Request, a: std.mem.Allocator) !void {
    const body = readBody(req, a, 4 << 20) catch return sendError(req, a, .payload_too_large, "body too large");
    const parsed = std.json.parseFromSliceLeaky(SpeakBody, a, body, .{ .ignore_unknown_fields = true }) catch
        return sendError(req, a, .bad_request, "invalid JSON body");
    if (parsed.text == null and parsed.chunks == null) return sendError(req, a, .bad_request, "text or chunks required");
    if (parsed.speed) |sp| if (!(sp >= 0.25 and sp <= 4.0)) return sendError(req, a, .bad_request, "speed must be 0.25-4");
    const result = s.core.speak(.{
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

fn speakFile(s: *Server, req: *http.Server.Request, a: std.mem.Allocator) !void {
    const body = readBody(req, a, 64 << 10) catch return sendError(req, a, .payload_too_large, "body too large");
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

fn modelRoute(s: *Server, req: *http.Server.Request, a: std.mem.Allocator, method: http.Method, rest: []const u8) !void {
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
};

fn patchSettings(s: *Server, req: *http.Server.Request, a: std.mem.Allocator) !void {
    const body = readBody(req, a, 64 << 10) catch return sendError(req, a, .payload_too_large, "body too large");
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
    s.core.setSettings(settings) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
    return sendJson(req, a, .ok, try s.core.getSettings(a));
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
            const job = if (e.job != 0) try jobIdStr(a, e.job) else null;
            const json = try std.json.Stringify.valueAlloc(a, .{
                .seq = e.seq,
                .type = @tagName(e.kind),
                .job = job,
                .index = e.index,
                .count = e.count,
                .state = e.stateStr(),
            }, .{ .emit_null_optional_fields = false });
            try body.writer.print("event: {s}\ndata: {s}\n\n", .{ @tagName(e.kind), json });
        }
        try body.writer.flush(); // drain into the chunked stream
        try body.flush(); // then push the socket buffer
    }
}
