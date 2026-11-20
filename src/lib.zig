//! libtalk: C interface for the macOS app (see include/talk.h).

const std = @import("std");
const Io = std.Io;
const http = std.http;
const config = @import("config.zig");
const Core = @import("core.zig").Core;
const core_mod = @import("core.zig");
const server = @import("server.zig");

const log = std.log.scoped(.libtalk);

const gpa = std.heap.c_allocator;

var started = std.atomic.Value(bool).init(false);
var threaded: Io.Threaded = undefined;
var arena_state: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
var srv: server.Server = undefined;
var listener: Io.net.Server = undefined;
var event_cb: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void = null;
var event_user: ?*anyopaque = null;

const TALK_OK = 0;
const TALK_ERR_SETUP = 1;
const TALK_ERR_PORT = 2;
const TALK_ERR_STARTED = 3;
const TALK_ERR_INTERNAL = 4;

export fn talk_start(home_c: ?[*:0]const u8, cb: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, user: ?*anyopaque) i32 {
    if (started.swap(true, .acq_rel)) return TALK_ERR_STARTED;
    threaded = Io.Threaded.init(gpa, .{});
    const io = threaded.io();
    const arena = arena_state.allocator();

    const home: []const u8 = if (home_c) |h| std.mem.span(h) else if (std.c.getenv("HOME")) |h| std.mem.span(h) else return TALK_ERR_SETUP;
    const paths = config.Paths.initHome(arena, home) catch return TALK_ERR_SETUP;
    const loaded = config.loadSettings(gpa, io, paths) catch return TALK_ERR_SETUP;
    const settings = loaded.value; // strings stay alive: `loaded` is never freed
    const token = config.loadOrCreateToken(arena, io, paths) catch return TALK_ERR_SETUP;

    // take the port over from a standalone `talktome serve`
    if (server.portInUse(io, settings.port)) {
        askToShutdown(io, settings.port, token);
        var waited: u32 = 0;
        while (server.portInUse(io, settings.port)) : (waited += 100) {
            if (waited >= 3000) return TALK_ERR_PORT;
            io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }

    const core = Core.create(gpa, io, paths, settings) catch return TALK_ERR_INTERNAL;
    srv = .{ .gpa = gpa, .io = io, .core = core, .token = token, .port = settings.port, .paths = paths };
    listener = server.listen(&srv) catch return TALK_ERR_PORT;
    const t = std.Thread.spawn(.{}, server.serveOn, .{ &srv, &listener }) catch return TALK_ERR_INTERNAL;
    t.detach();

    event_cb = cb;
    event_user = user;
    if (cb != null) {
        const et = std.Thread.spawn(.{}, eventLoop, .{core}) catch return TALK_ERR_INTERNAL;
        et.detach();
    }
    return TALK_OK;
}

fn askToShutdown(io: Io, port: u16, token: []const u8) void {
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/shutdown", .{port}) catch return;
    var auth_buf: [128]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return;
    _ = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "{}",
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "authorization", .value = auth }},
    }) catch |err| log.warn("could not ask the running server to stop: {t}", .{err});
}

fn eventLoop(core: *Core) void {
    var after = core.currentSeq();
    var batch: [64]core_mod.Event = undefined;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    while (true) {
        const n = core.waitEvents(after, &batch, 5000);
        for (batch[0..n]) |*e| {
            after = e.seq;
            _ = scratch.reset(.retain_capacity);
            const json = server.eventJson(scratch.allocator(), e) catch continue;
            const z = scratch.allocator().dupeSentinel(u8, json, 0) catch continue;
            if (event_cb) |cb| cb(event_user, z.ptr);
        }
    }
}

export fn talk_call(method_c: [*:0]const u8, path_c: [*:0]const u8, body_c: ?[*:0]const u8, status: ?*i32) ?[*:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ex: server.Exchange = .{ .body = if (body_c) |b| std.mem.span(b) else "" };

    if (!started.load(.acquire)) {
        ex.status = .service_unavailable;
        ex.reply = "{\"error\":\"talk_start has not been called\"}";
    } else if (std.meta.stringToEnum(http.Method, std.mem.span(method_c))) |method| {
        const full = std.mem.span(path_c);
        const path = if (std.mem.indexOfScalar(u8, full, '?')) |q| full[0..q] else full;
        server.dispatch(&srv, &ex, a, method, path) catch |err| {
            ex.status = .internal_server_error;
            ex.reply = std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"internal\"}";
        };
    } else {
        ex.status = .bad_request;
        ex.reply = "{\"error\":\"bad method\"}";
    }
    if (status) |s| s.* = @intFromEnum(ex.status);
    const out = std.heap.c_allocator.dupeSentinel(u8, ex.reply, 0) catch return null;
    return out.ptr;
}

export fn talk_free(p: ?[*:0]u8) void {
    if (p) |ptr| std.heap.c_allocator.free(std.mem.span(ptr));
}

/// The app recorded an answer to "Want the full report?": transcribe it with
/// the local recognizer, act on it, and return {"transcript": ..., "answer":
/// "yes"|"no"|null} (free with talk_free), or an {"error": ...}.
export fn talk_answer_audio(pcm: [*]const f32, n_samples: usize, sample_rate: i32) ?[*:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const reply: []const u8 = blk: {
        if (!started.load(.acquire)) break :blk "{\"error\":\"talk_start has not been called\"}";
        const heard = srv.core.answerFromAudio(a, pcm[0..n_samples], @intCast(sample_rate)) catch |err|
            break :blk std.fmt.allocPrint(a, "{{\"error\":\"{t}\"}}", .{err}) catch "{\"error\":\"internal\"}";
        break :blk std.json.Stringify.valueAlloc(a, .{
            .transcript = heard.transcript,
            .answer = if (heard.answer) |v| @as(?[]const u8, if (v) "yes" else "no") else null,
        }, .{}) catch "{\"error\":\"internal\"}";
    };
    const out = std.heap.c_allocator.dupeSentinel(u8, reply, 0) catch return null;
    return out.ptr;
}
