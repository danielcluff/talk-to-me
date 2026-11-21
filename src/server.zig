//! Local HTTP API on 127.0.0.1.
//!
//! Security: bound to loopback only; the Host header must name the loopback
//! address and port (DNS rebinding); every route except /v1/health needs
//! `Authorization: Bearer <token>`. The app and the CLI use the master token.
//! A paired browser extension gets a token of its own, which works only from
//! its own Origin and only for reading aloud and the player (see
//! extensionAllowed); "Forget" revokes it. Web pages never get in.
//!
//! Clients check the server before sending the master token: GET
//! /v1/health?challenge=X answers with HMAC-SHA256(token, X), which only the
//! real server can compute (another user could otherwise hold the port).

const std = @import("std");
const Io = std.Io;
const http = std.http;
const core_mod = @import("core.zig");
const Core = core_mod.Core;
const config = @import("config.zig");
const briefing_mod = @import("briefing.zig");

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
    extensions: Extensions = .{},
    /// open connections (each has a thread); see max_connections
    connections: std.atomic.Value(u32) = .init(0),
};

/// Above this many open connections new ones are closed at once, before a
/// thread is made for them. Clients are the app, hooks, the CLI and an
/// extension's event stream, so this is far above normal use.
pub const max_connections = 64;

/// Tokens of paired extensions, stored as SHA-256 hashes in extensions.json
/// (mode 0600). One per origin.
const Extensions = struct {
    mu: Io.Mutex = .init,
    loaded: bool = false,
    items: std.ArrayList(Entry) = .empty,

    const Entry = struct { origin: []const u8, token_sha256: []const u8 };
};

fn sha256Hex(token: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn extensionsPath(s: *Server, a: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(a, &.{ s.paths.root, "extensions.json" });
}

/// Caller holds extensions.mu.
fn loadExtensions(s: *Server) void {
    if (s.extensions.loaded) return;
    s.extensions.loaded = true;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = extensionsPath(s, a) catch return;
    const data = Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(1 << 20)) catch return;
    const list = std.json.parseFromSliceLeaky([]Extensions.Entry, a, data, .{ .ignore_unknown_fields = true }) catch return;
    for (list) |e| {
        const origin = s.gpa.dupe(u8, e.origin) catch return;
        const hash = s.gpa.dupe(u8, e.token_sha256) catch return;
        s.extensions.items.append(s.gpa, .{ .origin = origin, .token_sha256 = hash }) catch return;
    }
}

/// Caller holds extensions.mu.
fn saveExtensions(s: *Server) !void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try extensionsPath(s, a);
    try Io.Dir.cwd().createDirPath(s.io, s.paths.root);
    const json = try std.json.Stringify.valueAlloc(a, s.extensions.items.items, .{ .whitespace = .indent_2 });
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    const file = try Io.Dir.cwd().createFile(s.io, tmp, .{ .permissions = .fromMode(0o600), .truncate = true });
    {
        defer file.close(s.io);
        try file.writeStreamingAll(s.io, json);
    }
    try Io.Dir.rename(.cwd(), tmp, .cwd(), path, s.io);
}

/// The origin whose extension token this is, if any.
fn extensionForToken(s: *Server, a: std.mem.Allocator, auth: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth, prefix)) return null;
    const hash = sha256Hex(auth[prefix.len..]);
    s.extensions.mu.lockUncancelable(s.io);
    defer s.extensions.mu.unlock(s.io);
    loadExtensions(s);
    for (s.extensions.items.items) |e| {
        if (constantTimeEql(e.token_sha256, &hash)) return a.dupe(u8, e.origin) catch null;
    }
    return null;
}

/// A new random extension token (hex).
fn issueExtensionToken(s: *Server) ![64]u8 {
    var raw: [32]u8 = undefined;
    try s.io.randomSecure(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

fn storeExtensionToken(s: *Server, origin: []const u8, token: []const u8) !void {
    const hash = sha256Hex(token);
    s.extensions.mu.lockUncancelable(s.io);
    defer s.extensions.mu.unlock(s.io);
    loadExtensions(s);
    removeExtensionLocked(s, origin);
    try s.extensions.items.append(s.gpa, .{ .origin = try s.gpa.dupe(u8, origin), .token_sha256 = try s.gpa.dupe(u8, &hash) });
    try saveExtensions(s);
}

fn removeExtensionLocked(s: *Server, origin: []const u8) void {
    var i: usize = 0;
    while (i < s.extensions.items.items.len) {
        const e = s.extensions.items.items[i];
        if (std.mem.eql(u8, e.origin, origin)) {
            s.gpa.free(e.origin);
            s.gpa.free(e.token_sha256);
            _ = s.extensions.items.orderedRemove(i);
        } else i += 1;
    }
}

fn revokeExtension(s: *Server, origin: []const u8) !void {
    s.extensions.mu.lockUncancelable(s.io);
    defer s.extensions.mu.unlock(s.io);
    loadExtensions(s);
    removeExtensionLocked(s, origin);
    try saveExtensions(s);
}

/// What a paired extension may do: read aloud, drive the player, follow events.
pub fn extensionAllowed(method: http.Method, path: []const u8) bool {
    if (method == .GET) {
        return std.mem.eql(u8, path, "/v1/health") or std.mem.eql(u8, path, "/v1/player") or
            std.mem.eql(u8, path, "/v1/events") or std.mem.eql(u8, path, "/v1/voices");
    }
    if (method == .POST) {
        return std.mem.eql(u8, path, "/v1/speak") or std.mem.startsWith(u8, path, "/v1/player/");
    }
    return false;
}

fn constantTimeEql(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    var diff: u8 = 0;
    for (x, y) |p, q| diff |= p ^ q;
    return diff == 0;
}

/// Value of `name` in a query string ("a=1&b=2"), undecoded.
pub fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// HMAC-SHA256(token, "talktome-health:" ++ challenge), hex.
pub fn healthProof(token: []const u8, challenge: []const u8) [64]u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    var h = Hmac.init(token);
    h.update("talktome-health:");
    h.update(challenge);
    h.final(&mac);
    return std.fmt.bytesToHex(mac, .lower);
}

/// True if the server on `port` proves it holds `token` (without sending it).
pub fn verifyServer(gpa: std.mem.Allocator, io: Io, port: u16, token: []const u8) bool {
    if (token.len == 0) return false;
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const challenge = std.fmt.bytesToHex(raw, .lower);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: Io.Writer.Allocating = .init(a);
    const url = std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/health?challenge={s}", .{ port, &challenge }) catch return false;
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .response_writer = &body.writer,
    }) catch return false;
    if (res.status != .ok) return false;
    const R = struct { proof: []const u8 = "" };
    const r = std.json.parseFromSliceLeaky(R, a, body.written(), .{ .ignore_unknown_fields = true }) catch return false;
    const want = healthProof(token, &challenge);
    return constantTimeEql(r.proof, &want);
}

/// Browser extension pairing. An extension asks (POST /v1/pair, from an
/// extension Origin only); the app or CLI approves it; the extension then
/// collects the token once with its pairing secret.
const Pairing = struct {
    mu: Io.Mutex = .init,
    next_id: u32 = 1,
    items: [8]?Pair = @splat(null),
    /// origins recently denied, which may not ask again for a while
    denied: [8]struct { origin_hash: u64 = 0, until_ms: i64 = 0 } = @splat(.{}),

    /// an unanswered request expires; one at a time may wait for an answer
    const pending_ms = 120_000;
    const denied_cooldown_ms = 60_000;

    const Pair = struct {
        id: u32,
        origin: [160]u8 = @splat(0),
        secret: [32]u8,
        code: [4]u8,
        created_ms: i64 = 0,
        /// the extension's own token, handed out once after approval
        token: [64]u8 = @splat(0),
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
        if (s.connections.fetchAdd(1, .acq_rel) >= max_connections) {
            _ = s.connections.fetchSub(1, .acq_rel);
            log.warn("too many connections; closing a new one", .{});
            stream.close(s.io);
            continue;
        }
        // 2 MB, not the 16 MB default: requests use heap arenas (markdown
        // parsing included), so 64 connections stay cheap
        const t = std.Thread.spawn(.{ .stack_size = 2 << 20 }, connection, .{ s, stream }) catch |err| {
            log.err("thread spawn failed: {t}", .{err});
            _ = s.connections.fetchSub(1, .acq_rel);
            stream.close(s.io);
            continue;
        };
        t.detach();
    }
}

fn connection(s: *Server, stream: Io.net.Stream) void {
    defer _ = s.connections.fetchSub(1, .acq_rel);
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
    return constantTimeEql(auth[prefix.len..], s.token);
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).toNanoseconds(), std.time.ns_per_ms));
}

/// One API call, transport-independent: the request body in, status and JSON
/// out. The HTTP server and the in-process C interface (lib.zig) both use it.
pub const Exchange = struct {
    body: []const u8 = "",
    /// the query string, without '?'
    query: []const u8 = "",
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

    const public = method == .GET and std.mem.eql(u8, path, "/v1/health");
    // web pages never get in; a paired extension does, with its own token
    if (head.origin) |origin| {
        if (!isExtensionOrigin(origin) or !originPaired(s, a, origin)) {
            return respondError(req, a, .forbidden, "this origin is not paired with Talk to Me");
        }
    }
    if (!public) {
        if (head.origin == null and tokenOk(s, head.auth)) {
            // the app or the CLI: everything
        } else if (extensionForToken(s, a, head.auth)) |ext_origin| {
            // an extension token works only from its own origin (or with no
            // Origin header at all), and only for its routes
            if (head.origin) |o| if (!std.mem.eql(u8, o, ext_origin)) return respondError(req, a, .forbidden, "this token belongs to another extension");
            if (!originPaired(s, a, ext_origin)) return respondError(req, a, .unauthorized, "this extension was unpaired");
            if (!extensionAllowed(method, path)) return respondError(req, a, .forbidden, "not allowed for a browser extension");
        } else {
            return respondError(req, a, .unauthorized, "missing or bad token");
        }
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/events")) return events(s, req, a);

    var ex: Exchange = .{ .query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "" };
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
        // proof that this server holds the token (see verifyServer)
        const proof: ?[]const u8 = if (queryParam(req.query, "challenge")) |ch|
            (if (ch.len > 0 and ch.len <= 128) try a.dupe(u8, &healthProof(s.token, ch)) else null)
        else
            null;
        return sendJson(req, a, .ok, .{ .ok = true, .version = version, .model = p.model, .model_state = p.model_state, .queued = p.queued, .state = p.state, .proof = proof });
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
    if (method == .DELETE and std.mem.eql(u8, path, "/v1/history")) {
        s.core.clearHistory() catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
        return sendJson(req, a, .ok, .{ .ok = true });
    }
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
    if (std.mem.eql(u8, action, "answer-audio")) {
        // body: little-endian float32 mono samples; ?rate=16000
        const rate_text = queryParam(req.query, "rate") orelse "16000";
        const rate = std.fmt.parseInt(u32, rate_text, 10) catch return sendError(req, a, .bad_request, "rate must be a number");
        if (rate < 8000 or rate > 192_000) return sendError(req, a, .bad_request, "rate must be 8000-192000");
        if (req.body.len < 4 or req.body.len % 4 != 0) return sendError(req, a, .bad_request, "body must be float32 samples");
        const samples = try a.alloc(f32, req.body.len / 4);
        for (samples, 0..) |*o, i| o.* = @bitCast(std.mem.readInt(u32, req.body[i * 4 ..][0..4], .little));
        const heard = s.core.answerFromAudio(a, samples, rate) catch |err| return sendError(req, a, .unprocessable_entity, @errorName(err));
        return sendJson(req, a, .ok, .{ .transcript = heard.transcript, .answer = if (heard.answer) |v| @as(?[]const u8, if (v) "yes" else "no") else null });
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
    if (method == .POST and std.mem.eql(u8, action, "clean")) {
        @import("models/models.zig").removePartials(a, s.io, try std.fs.path.join(a, &.{ s.paths.models, m.id })) catch {};
        return sendJson(req, a, .ok, .{ .ok = true });
    }
    if (method == .POST and std.mem.eql(u8, action, "activate")) {
        var settings = try s.core.beginEdit(a);
        defer s.core.endEdit();
        switch (m.kind) {
            .summary => {
                settings.briefing.backend = .local;
                settings.briefing.model = m.id;
                s.core.setSettings(settings) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
                return sendJson(req, a, .ok, .{ .ok = true, .model = m.id, .used_for = "briefing" });
            },
            .listening => {
                settings.briefing.recognizer = m.id;
                s.core.setSettings(settings) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
                return sendJson(req, a, .ok, .{ .ok = true, .model = m.id, .used_for = "listening" });
            },
            .voice => {},
        }
        if (!std.mem.eql(u8, m.id, settings.model)) settings.voice = "";
        settings.model = m.id;
        s.core.setSettings(settings) catch |err| return sendError(req, a, .internal_server_error, @errorName(err));
        return sendJson(req, a, .ok, .{ .ok = true, .model = m.id });
    }
    if (method == .DELETE and action.len == 0) {
        // deleting what's in use switches to something safe first
        var settings = try s.core.beginEdit(a);
        var edit_open = true;
        defer if (edit_open) s.core.endEdit();
        var changed = false;
        switch (m.kind) {
            .voice => if (std.mem.eql(u8, settings.model, m.id)) {
                const views = try s.core.modelViews(a);
                for (views) |v| if (v.kind == .voice and v.installed and !std.mem.eql(u8, v.id, m.id)) {
                    settings.model = v.id;
                    settings.voice = "";
                    changed = true;
                    break;
                };
            },
            // never fall back to a cloud summarizer the person didn't pick
            .summary => if (settings.briefing.backend == .local and std.mem.eql(u8, settings.briefing.model, m.id)) {
                settings.briefing.enabled = false;
                settings.briefing.model = "";
                changed = true;
            },
            .listening => if (std.mem.eql(u8, settings.briefing.recognizer, m.id)) {
                settings.briefing.recognizer = "apple";
                changed = true;
            },
        }
        if (changed) s.core.setSettings(settings) catch {};
        s.core.endEdit();
        edit_open = false;
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
    var settings = try s.core.beginEdit(a);
    defer s.core.endEdit();
    if (patch.model) |m| {
        const found = s.core.catalog.find(m) orelse return sendError(req, a, .bad_request, "unknown model");
        if (found.kind != .voice) return sendError(req, a, .bad_request, "that isn't a voice model");
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
        if (b.ollama_url) |v| {
            if (!briefing_mod.validOllamaUrl(v)) return sendError(req, a, .bad_request, "ollama_url must be an http:// or https:// address");
            cur.ollama_url = v;
        }
        if (b.min_words) |v| cur.min_words = v;
        if (b.timeout_seconds) |v| cur.timeout_seconds = briefing_mod.clampTimeout(v);
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
    const now = nowMs(s.io);
    p.created_ms = now;
    const origin_hash = std.hash.Wyhash.hash(0, o);

    s.pairing.mu.lockUncancelable(s.io);
    // one request may wait for an answer at a time, so an extension can't
    // stack up dialogs; a denied one waits before it may ask again
    for (&s.pairing.items) |*it| if (it.*) |*q| if (q.status == .pending and now - q.created_ms > Pairing.pending_ms) {
        it.* = null;
    };
    const waiting = for (s.pairing.items) |it| {
        if (it) |q| if (q.status == .pending) break true;
    } else false;
    const cooling = for (s.pairing.denied) |d| {
        if (d.origin_hash == origin_hash and now < d.until_ms) break true;
    } else false;
    if (waiting or cooling) {
        s.pairing.mu.unlock(s.io);
        return respondError(req, a, .too_many_requests, if (waiting) "another pairing request is waiting for an answer" else "denied recently; try again in a minute");
    }
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
                token = try a.dupe(u8, &p.token);
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
        // revoke the token first: from here on the extension is out
        try revokeExtension(s, f.origin);
        var settings = try s.core.beginEdit(a);
        defer s.core.endEdit();
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

        // the extension's own token, stored (hashed) before it can collect it
        const token = try issueExtensionToken(s);
        var origin: ?[]const u8 = null;
        s.pairing.mu.lockUncancelable(s.io);
        const now = nowMs(s.io);
        for (&s.pairing.items) |*slot| if (slot.*) |*p| if (p.id == id and p.status == .pending) {
            origin = a.dupe(u8, p.originStr()) catch null;
            if (approve) {
                p.token = token;
            } else {
                // remember the denial (oldest entry makes room)
                var oldest: usize = 0;
                for (s.pairing.denied, 0..) |d, k| if (d.until_ms < s.pairing.denied[oldest].until_ms) {
                    oldest = k;
                };
                s.pairing.denied[oldest] = .{ .origin_hash = std.hash.Wyhash.hash(0, p.originStr()), .until_ms = now + Pairing.denied_cooldown_ms };
            }
        };
        s.pairing.mu.unlock(s.io);
        const o = origin orelse return sendError(req, a, .not_found, "no pending pairing with that id");
        if (approve) {
            try storeExtensionToken(s, o, &token);
            var settings = try s.core.beginEdit(a);
            defer s.core.endEdit();
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
        // only now may the extension collect its token (or learn it was denied)
        s.pairing.mu.lockUncancelable(s.io);
        for (&s.pairing.items) |*slot| if (slot.*) |*p| if (p.id == id and p.status == .pending) {
            p.status = if (approve) .approved else .denied;
        };
        s.pairing.mu.unlock(s.io);
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
    _ = a;
    var after = s.core.currentSeq();
    var batch: [64]core_mod.Event = undefined;
    var since_ping: u64 = 0;
    // a stream can stay open for days: event JSON goes in a scratch arena
    // that is reset for every batch, not the request arena
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
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
        _ = scratch.reset(.retain_capacity);
        for (batch[0..n]) |*e| {
            after = e.seq;
            const json = try eventJson(scratch.allocator(), e);
            try body.writer.print("event: {s}\ndata: {s}\n\n", .{ @tagName(e.kind), json });
        }
        try body.writer.flush(); // drain into the chunked stream
        try body.flush(); // then push the socket buffer
    }
}
