//! talktome: the server (`talktome serve`) and its command-line client.
//!
//! Client commands talk to the local API (127.0.0.1:9932 by default) with the
//! token from ~/Library/Application Support/TalkToMe/token. When no server is
//! running, the client starts one in the background (`talktome serve`, logs in
//! ~/Library/Logs/TalkToMe/server.log). In the app, the menu bar process will
//! host the same server instead.

const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const Core = @import("core.zig").Core;
const server = @import("server.zig");
const integrations = @import("integrations.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub const usage =
    \\Usage: talktome [options] [TEXT | FILE.md | FILE.txt]
    \\       some-command | talktome [options]
    \\       talktome <command> [args]
    \\
    \\Speak text or a markdown/text file. Without TEXT or FILE, reads stdin.
    \\
    \\Options:
    \\  -v, --voice NAME     voice (see `talktome voices`)
    \\  -s, --speed X        speaking speed, 0.25-4 (default from settings)
    \\  -p, --policy P       queue | interrupt | replace | drop_if_busy
    \\                       (default: interrupt for files/args, queue for stdin)
    \\      --app NAME       source app (default: cli)
    \\      --label TEXT     source label shown in the menu
    \\      --session ID     source session (used by --policy replace)
    \\      --text           treat input as plain text, not markdown
    \\  -w, --wait           block until the job finishes
    \\
    \\Commands:
    \\  serve [--port N]     run the server in the foreground
    \\  stop                 stop speaking and clear the queue
    \\  pause | resume | toggle
    \\  next | previous      jump one sentence
    \\  skip                 skip to the next queued item
    \\  status               player state
    \\  jobs                 current, queued and recent jobs
    \\  voices               voices of the active model
    \\  models               list models
    \\  models download ID   download a model (e.g. kokoro)
    \\  models use ID        make a model active
    \\  models remove ID     delete a model's files
    \\  config               show settings
    \\  config set KEY VALUE set a setting (voice, speed, model, ...)
    \\
    \\Agents:
    \\  install TARGET       claude | codex | opencode | herdr
    \\  uninstall TARGET
    \\  integrations [--json] what is installed
    \\  answer yes|no        answer "Want the full report?" after a briefing
    \\  report               read the full report behind the last briefing
    \\  pair                 browser extensions waiting for approval, and paired ones
    \\  pair approve|deny ID
    \\  pair forget ORIGIN   unpair an extension
    \\  hook claude|codex|opencode   (called by the agents' hooks)
    \\  mcp [--app NAME]     MCP server on stdio (speak, stop, list_voices)
    \\  help
    \\
;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    paths: config.Paths,
    environ: *std.process.Environ.Map,
    port: u16,
    token: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.Reported => std.process.exit(1), // message already printed
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args: std.ArrayList([]const u8) = .empty;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    while (it.next()) |a| try args.append(arena, a);

    const paths = try config.Paths.init(arena, init.environ_map);
    var loaded = try config.loadSettings(init.gpa, io, paths);
    defer loaded.deinit();

    var ctx: Ctx = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = io,
        .paths = paths,
        .environ = init.environ_map,
        .port = loaded.value.port,
    };

    const cmd = if (args.items.len > 0) args.items[0] else "";
    const rest = if (args.items.len > 0) args.items[1..] else args.items[0..0];

    if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) return out(io, usage);
    if (eql(cmd, "serve")) return serve(&ctx, loaded.value, rest);

    const simple = [_][]const u8{ "stop", "pause", "resume", "toggle", "next", "previous", "skip" };
    for (simple) |s| if (eql(cmd, s)) {
        try ensureServer(&ctx);
        const body = try request(&ctx, .POST, try std.fmt.allocPrint(arena, "/v1/player/{s}", .{s}), null);
        return printPlayer(&ctx, body);
    };
    if (eql(cmd, "status")) {
        try ensureServer(&ctx);
        return printPlayer(&ctx, try request(&ctx, .GET, "/v1/player", null));
    }
    if (eql(cmd, "jobs")) return jobs(&ctx);
    if (eql(cmd, "voices")) return voices(&ctx);
    if (eql(cmd, "models")) return modelsCmd(&ctx, rest);
    if (eql(cmd, "config")) return configCmd(&ctx, rest);
    if (eql(cmd, "pair")) return pairCmd(&ctx, rest);
    if (eql(cmd, "answer")) return answerCmd(&ctx, rest);
    if (eql(cmd, "report")) {
        try ensureServer(&ctx);
        _ = try request(&ctx, .POST, "/v1/briefing/last", "{}");
        return out(io, "reading the last full report\n");
    }
    if (eql(cmd, "hook")) return integrations.hook(&ctx, rest);
    if (eql(cmd, "mcp")) return integrations.mcp(&ctx, rest);
    if (eql(cmd, "install")) return integrations.installCmd(&ctx, rest, true);
    if (eql(cmd, "uninstall")) return integrations.installCmd(&ctx, rest, false);
    if (eql(cmd, "integrations")) return integrations.integrationsCmd(&ctx, rest);
    return speak(&ctx, args.items);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn out(io: Io, text: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, text);
}

pub fn outf(ctx: *Ctx, comptime fmt: []const u8, args: anytype) !void {
    try out(ctx.io, try std.fmt.allocPrint(ctx.arena, fmt, args));
}

pub fn fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) error{Reported} {
    const msg = std.fmt.allocPrint(ctx.arena, "talktome: " ++ fmt ++ "\n", args) catch "talktome: error\n";
    Io.File.stderr().writeStreamingAll(ctx.io, msg) catch {};
    return error.Reported;
}

// ------------------------------------------------------------------ server

fn serve(ctx: *Ctx, settings: config.Settings, rest: []const []const u8) !void {
    var port = settings.port;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (eql(rest[i], "--port") and i + 1 < rest.len) {
            port = try std.fmt.parseInt(u16, rest[i + 1], 10);
            i += 1;
        }
    }
    const token = try config.loadOrCreateToken(ctx.arena, ctx.io, ctx.paths);
    const core = try Core.create(ctx.gpa, ctx.io, ctx.paths, settings);
    defer core.destroy();
    if (server.portInUse(ctx.io, port)) return fail(ctx, "a server is already running on port {d}", .{port});
    var srv: server.Server = .{ .gpa = ctx.gpa, .io = ctx.io, .core = core, .token = token, .port = port, .paths = ctx.paths, .allow_shutdown = true };
    try server.run(&srv);
}

// ------------------------------------------------------------------ client

const Response = struct { status: std.http.Status, body: []const u8 };

pub fn rawRequest(ctx: *Ctx, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Response {
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    var body: Io.Writer.Allocating = .init(ctx.arena);
    const url = try std.fmt.allocPrint(ctx.arena, "http://127.0.0.1:{d}{s}", .{ ctx.port, path });
    const auth = try std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{ctx.token});
    // std.http.Client declares a chunked body on a bodiless POST and never
    // sends it, so the server would wait; always send at least "{}".
    const body_payload: ?[]const u8 = payload orelse if (method.requestHasBody()) @as([]const u8, "{}") else null;
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body_payload,
        .keep_alive = false,
        .response_writer = &body.writer,
        .headers = .{ .content_type = if (body_payload != null) .{ .override = "application/json" } else .default },
        .extra_headers = &.{.{ .name = "authorization", .value = auth }},
    });
    return .{ .status = res.status, .body = body.written() };
}

/// Request that must succeed (2xx); prints the server's error otherwise.
pub fn request(ctx: *Ctx, method: std.http.Method, path: []const u8, payload: ?[]const u8) ![]const u8 {
    const res = rawRequest(ctx, method, path, payload) catch |err|
        return fail(ctx, "cannot reach the server on port {d}: {t}", .{ ctx.port, err });
    if (@intFromEnum(res.status) >= 300) {
        const msg = errorMessage(ctx.arena, res.body) orelse res.body;
        return fail(ctx, "{s}", .{msg});
    }
    return res.body;
}

fn errorMessage(a: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const E = struct { @"error": []const u8 };
    const e = std.json.parseFromSliceLeaky(E, a, body, .{ .ignore_unknown_fields = true }) catch return null;
    return e.@"error";
}

fn healthy(ctx: *Ctx) bool {
    const res = rawRequest(ctx, .GET, "/v1/health", null) catch return false;
    return res.status == .ok;
}

/// Launch the menu bar app in the background if it is installed
/// (LaunchServices knows its bundle id). Returns false if there is no app.
fn openApp(ctx: *Ctx) bool {
    if (ctx.environ.get("TALKTOME_HOME") != null) return false; // tests use a standalone server
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ "/usr/bin/open", "-g", "-b", "dev.talktome.app" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(ctx.io) catch return false;
    return term.success();
}

/// Make sure a server is running (start one in the background if not) and
/// load the token.
pub fn ensureServer(ctx: *Ctx) !void {
    if (!healthy(ctx) and openApp(ctx)) {
        // the app hosts the server; give it a moment to come up
        var waited: u32 = 0;
        while (!healthy(ctx) and waited < 10_000) : (waited += 100) try ctx.io.sleep(.fromMilliseconds(100), .awake);
    }
    if (!healthy(ctx)) {
        const exe = try std.process.executablePathAlloc(ctx.io, ctx.arena);
        try Io.Dir.cwd().createDirPath(ctx.io, ctx.paths.logs);
        const log_path = try std.fs.path.join(ctx.arena, &.{ ctx.paths.logs, "server.log" });
        var child = try std.process.spawn(ctx.io, .{
            .argv = &.{ "/bin/sh", "-c", "nohup \"$0\" serve >>\"$1\" 2>&1 &", exe, log_path },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try child.wait(ctx.io);
        var waited: u32 = 0;
        while (!healthy(ctx)) : (waited += 100) {
            if (waited > 15_000) return fail(ctx, "the server did not start; see {s}", .{log_path});
            try ctx.io.sleep(.fromMilliseconds(100), .awake);
        }
    }
    ctx.token = config.readToken(ctx.arena, ctx.io, ctx.paths) catch |err|
        return fail(ctx, "cannot read the API token ({t}) at {s}", .{ err, ctx.paths.token });
}

// ------------------------------------------------------------------ speak

fn speak(ctx: *Ctx, args: []const []const u8) !void {
    var voice: ?[]const u8 = null;
    var speed: ?f32 = null;
    var policy: ?[]const u8 = null;
    var app: []const u8 = "cli";
    var label: []const u8 = "";
    var session: []const u8 = "";
    var plain = false;
    var wait = false;
    var words: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_val = i + 1 < args.len;
        if ((eql(a, "-v") or eql(a, "--voice")) and has_val) {
            i += 1;
            voice = args[i];
        } else if ((eql(a, "-s") or eql(a, "--speed")) and has_val) {
            i += 1;
            speed = std.fmt.parseFloat(f32, args[i]) catch return fail(ctx, "bad speed: {s}", .{args[i]});
        } else if ((eql(a, "-p") or eql(a, "--policy")) and has_val) {
            i += 1;
            policy = args[i];
        } else if (eql(a, "--app") and has_val) {
            i += 1;
            app = args[i];
        } else if (eql(a, "--label") and has_val) {
            i += 1;
            label = args[i];
        } else if (eql(a, "--session") and has_val) {
            i += 1;
            session = args[i];
        } else if (eql(a, "--text")) {
            plain = true;
        } else if (eql(a, "-w") or eql(a, "--wait")) {
            wait = true;
        } else if (std.mem.startsWith(u8, a, "-") and a.len > 1) {
            return fail(ctx, "unknown option {s} (see talktome help)", .{a});
        } else {
            try words.append(ctx.arena, a);
        }
    }

    var payload: Io.Writer.Allocating = .init(ctx.arena);
    var path: []const u8 = "/v1/speak";
    const source = .{ .app = app, .label = label, .session = session };

    if (words.items.len == 1 and server.formatForPath(words.items[0]) != null) {
        // a file: the server reads it (it must be .md/.markdown/.txt)
        const abs = Io.Dir.cwd().realPathFileAlloc(ctx.io, words.items[0], ctx.arena) catch
            return fail(ctx, "cannot open {s}", .{words.items[0]});
        path = "/v1/speak/file";
        var src = source;
        if (eql(app, "cli")) src.app = "file";
        try std.json.Stringify.value(.{
            .path = abs,
            .voice = voice,
            .speed = speed,
            .policy = policy orelse "interrupt",
            .source = src,
        }, .{ .emit_null_optional_fields = false }, &payload.writer);
    } else {
        var text: []const u8 = undefined;
        var default_policy: []const u8 = "interrupt";
        if (words.items.len > 0) {
            text = try std.mem.join(ctx.arena, " ", words.items);
        } else {
            if (try Io.File.stdin().isTty(ctx.io)) {
                try out(ctx.io, usage);
                return;
            }
            var buf: [4096]u8 = undefined;
            var r = Io.File.stdin().reader(ctx.io, &buf);
            text = try r.interface.allocRemaining(ctx.arena, .limited(4 << 20));
            default_policy = "queue";
        }
        try std.json.Stringify.value(.{
            .text = text,
            .format = if (plain) "text" else "markdown",
            .voice = voice,
            .speed = speed,
            .policy = policy orelse default_policy,
            .source = source,
        }, .{ .emit_null_optional_fields = false }, &payload.writer);
    }

    try ensureServer(ctx);
    const body = try request(ctx, .POST, path, payload.written());
    const R = struct { job_id: ?[]const u8 = null, chunks: usize = 0, position: usize = 0, dropped: ?[]const u8 = null, summarizing: bool = false };
    const r = std.json.parseFromSliceLeaky(R, ctx.arena, body, .{ .ignore_unknown_fields = true }) catch R{};
    if (r.dropped) |reason| return outf(ctx, "not queued: {s}\n", .{reason});
    if (r.summarizing) return out(ctx.io, "summarizing for a briefing\n");
    const id = r.job_id orelse return fail(ctx, "unexpected response: {s}", .{body});
    if (!wait) {
        if (r.position == 0)
            return outf(ctx, "speaking {s} ({d} sentences)\n", .{ id, r.chunks })
        else
            return outf(ctx, "queued {s} ({d} sentences, position {d})\n", .{ id, r.chunks, r.position });
    }
    try waitForJob(ctx, id);
}

fn waitForJob(ctx: *Ctx, id: []const u8) !void {
    const J = struct { id: u64, state: []const u8 };
    const L = struct { jobs: []J };
    const want = server.parseJobId(id) orelse return;
    while (true) {
        try ctx.io.sleep(.fromMilliseconds(300), .awake);
        const body = try request(ctx, .GET, "/v1/jobs", null);
        const list = std.json.parseFromSliceLeaky(L, ctx.arena, body, .{ .ignore_unknown_fields = true }) catch continue;
        for (list.jobs) |j| if (j.id == want) {
            if (!eql(j.state, "queued") and !eql(j.state, "playing")) {
                if (!eql(j.state, "done")) try outf(ctx, "{s}: {s}\n", .{ id, j.state });
                return;
            }
        };
    }
}

// ------------------------------------------------------------------ views

fn printPlayer(ctx: *Ctx, body: []const u8) !void {
    const P = struct {
        state: []const u8,
        job: ?u64 = null,
        app: []const u8 = "",
        label: []const u8 = "",
        index: usize = 0,
        count: usize = 0,
        queued: usize = 0,
        model: []const u8 = "",
        model_state: []const u8 = "",
        model_error: []const u8 = "",
    };
    const p = std.json.parseFromSliceLeaky(P, ctx.arena, body, .{ .ignore_unknown_fields = true }) catch
        return fail(ctx, "unexpected response: {s}", .{body});
    if (p.job) |j| {
        try outf(ctx, "{s}: j_{d} from {s}{s}{s} (sentence {d}/{d}), {d} queued\n", .{
            p.state, j, p.app, if (p.label.len > 0) " · " else "", p.label, @min(p.index + 1, p.count), p.count, p.queued,
        });
    } else {
        try outf(ctx, "{s}, {d} queued\n", .{ p.state, p.queued });
    }
    try outf(ctx, "model: {s} ({s})\n", .{ p.model, p.model_state });
    if (p.model_error.len > 0) try outf(ctx, "  {s}\n", .{p.model_error});
}

fn jobs(ctx: *Ctx) !void {
    try ensureServer(ctx);
    const body = try request(ctx, .GET, "/v1/jobs", null);
    const J = struct { id: u64, app: []const u8, label: []const u8, preview: []const u8, chunks: usize, state: []const u8, index: ?usize = null };
    const L = struct { jobs: []J };
    const list = try std.json.parseFromSliceLeaky(L, ctx.arena, body, .{ .ignore_unknown_fields = true });
    if (list.jobs.len == 0) return out(ctx.io, "no jobs\n");
    for (list.jobs) |j| {
        const preview = j.preview[0..@min(j.preview.len, 60)];
        try outf(ctx, "j_{d:<5} {s:<11} {s:<10} {d:>3} sentences  {s}{s}\n", .{
            j.id, j.state, j.app, j.chunks, preview, if (j.preview.len > 60) "…" else "",
        });
    }
}

fn voices(ctx: *Ctx) !void {
    try ensureServer(ctx);
    const body = try request(ctx, .GET, "/v1/voices", null);
    const V = struct { name: []const u8, accent: []const u8, gender: []const u8, default: bool };
    const L = struct { model: []const u8, voices: []V };
    const list = try std.json.parseFromSliceLeaky(L, ctx.arena, body, .{ .ignore_unknown_fields = true });
    try outf(ctx, "{s}: {d} English voices\n", .{ list.model, list.voices.len });
    for (list.voices) |v| {
        try outf(ctx, "  {s:<14} {s:<3} {s:<7}{s}\n", .{ v.name, v.accent, v.gender, if (v.default) "  (default)" else "" });
    }
}

const ModelRow = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
    recommended: bool = false,
    size: u64,
    installed: bool,
    active: bool,
    loaded: bool = false,
    download: ?struct { done: u64, total: u64, active: bool, @"error": []const u8 = "" } = null,
};

fn fetchModels(ctx: *Ctx) ![]ModelRow {
    const body = try request(ctx, .GET, "/v1/models", null);
    const L = struct { models: []ModelRow };
    return (try std.json.parseFromSliceLeaky(L, ctx.arena, body, .{ .ignore_unknown_fields = true })).models;
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1_000_000.0;
}

fn modelsCmd(ctx: *Ctx, rest: []const []const u8) !void {
    try ensureServer(ctx);
    if (rest.len == 0) {
        for (try fetchModels(ctx)) |m| {
            try outf(ctx, "{s} {s:<10} {s:<14} {d:>6.0} MB  {s}{s}\n", .{
                if (m.active) "*" else " ",
                m.id,
                if (m.installed) "installed" else "not installed",
                mb(m.size),
                m.description,
                if (m.recommended) "  (recommended)" else "",
            });
        }
        return;
    }
    const sub = rest[0];
    if (rest.len < 2) return fail(ctx, "usage: talktome models {s} ID", .{sub});
    const id = rest[1];
    if (eql(sub, "download")) {
        _ = try request(ctx, .POST, try std.fmt.allocPrint(ctx.arena, "/v1/models/{s}/download", .{id}), "{}");
        const tty = Io.File.stdout().isTty(ctx.io) catch false;
        var last_pct: i64 = -1;
        while (true) {
            try ctx.io.sleep(.fromMilliseconds(500), .awake);
            const row = for (try fetchModels(ctx)) |m| {
                if (eql(m.id, id)) break m;
            } else return fail(ctx, "unknown model {s}", .{id});
            const d = row.download orelse continue;
            const pct: i64 = if (d.total > 0) @intCast(d.done * 100 / d.total) else 0;
            if (pct != last_pct) {
                if (tty)
                    try outf(ctx, "\r{s}: {d:.1} / {d:.1} MB ({d}%)", .{ id, mb(d.done), mb(d.total), pct })
                else if (@mod(pct, 10) == 0)
                    try outf(ctx, "{s}: {d}%\n", .{ id, pct });
                last_pct = pct;
            }
            if (!d.active) {
                if (tty) try out(ctx.io, "\n");
                if (d.@"error".len > 0) return fail(ctx, "download failed: {s}", .{d.@"error"});
                return outf(ctx, "{s} installed and verified\n", .{id});
            }
        }
    } else if (eql(sub, "use")) {
        const body = try request(ctx, .POST, try std.fmt.allocPrint(ctx.arena, "/v1/models/{s}/activate", .{id}), "{}");
        const U = struct { used_for: []const u8 = "voice" };
        const u = std.json.parseFromSliceLeaky(U, ctx.arena, body, .{ .ignore_unknown_fields = true }) catch U{};
        if (eql(u.used_for, "briefing")) return outf(ctx, "briefings now summarize with {s} (local)\n", .{id});
        if (eql(u.used_for, "listening")) return outf(ctx, "answers are now recognized with {s}\n", .{id});
        return outf(ctx, "active voice model: {s}\n", .{id});
    } else if (eql(sub, "remove")) {
        _ = try request(ctx, .DELETE, try std.fmt.allocPrint(ctx.arena, "/v1/models/{s}", .{id}), null);
        return outf(ctx, "removed {s}\n", .{id});
    } else if (eql(sub, "cancel")) {
        _ = try request(ctx, .POST, try std.fmt.allocPrint(ctx.arena, "/v1/models/{s}/cancel", .{id}), "{}");
        return;
    }
    return fail(ctx, "unknown models command {s}", .{sub});
}

fn configCmd(ctx: *Ctx, rest: []const []const u8) !void {
    try ensureServer(ctx);
    if (rest.len == 0) {
        const body = try request(ctx, .GET, "/v1/settings", null);
        try out(ctx.io, body);
        return out(ctx.io, "\n");
    }
    if (eql(rest[0], "set") and rest.len == 3) {
        const key = rest[1];
        const value = rest[2];
        var payload: Io.Writer.Allocating = .init(ctx.arena);
        const numeric = eql(key, "speed") or eql(key, "idle_unload_minutes") or eql(key, "dedupe_seconds");
        try payload.writer.writeAll("{");
        try std.json.Stringify.value(key, .{}, &payload.writer);
        try payload.writer.writeAll(":");
        if (numeric) try payload.writer.writeAll(value) else try std.json.Stringify.value(value, .{}, &payload.writer);
        try payload.writer.writeAll("}");
        const body = try request(ctx, .PATCH, "/v1/settings", payload.written());
        try out(ctx.io, body);
        return out(ctx.io, "\n");
    }
    return fail(ctx, "usage: talktome config [set KEY VALUE]", .{});
}

fn pairCmd(ctx: *Ctx, rest: []const []const u8) !void {
    try ensureServer(ctx);
    if (rest.len == 0) {
        const P = struct { id: u32, origin: []const u8, code: []const u8 };
        const L = struct { pending: []P, paired: []const []const u8 };
        const list = try std.json.parseFromSliceLeaky(L, ctx.arena, try request(ctx, .GET, "/v1/pair", null), .{ .ignore_unknown_fields = true });
        if (list.pending.len == 0) try out(ctx.io, "no pairing requests\n");
        for (list.pending) |p| try outf(ctx, "request {d}: code {s} from {s}\n", .{ p.id, p.code, p.origin });
        for (list.paired) |o| try outf(ctx, "paired: {s}\n", .{o});
        return;
    }
    if ((eql(rest[0], "approve") or eql(rest[0], "deny")) and rest.len == 2) {
        _ = try request(ctx, .POST, try std.fmt.allocPrint(ctx.arena, "/v1/pair/{s}/{s}", .{ rest[1], rest[0] }), "{}");
        return outf(ctx, "{s}d request {s}\n", .{ if (eql(rest[0], "approve")) "approve" else "denie", rest[1] });
    }
    if (eql(rest[0], "forget") and rest.len == 2) {
        const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .origin = rest[1] }, .{});
        _ = try request(ctx, .POST, "/v1/pair/forget", body);
        return outf(ctx, "unpaired {s}\n", .{rest[1]});
    }
    return fail(ctx, "usage: talktome pair [approve|deny ID | forget ORIGIN]", .{});
}

fn answerCmd(ctx: *Ctx, rest: []const []const u8) !void {
    if (rest.len != 1 or !(eql(rest[0], "yes") or eql(rest[0], "no"))) return fail(ctx, "usage: talktome answer yes|no", .{});
    try ensureServer(ctx);
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .answer = rest[0] }, .{});
    const res = rawRequest(ctx, .POST, "/v1/briefing/answer", body) catch return fail(ctx, "cannot reach the server", .{});
    if (res.status == .conflict) return out(ctx.io, "no question is waiting\n");
    return outf(ctx, "{s}\n", .{if (eql(rest[0], "yes")) "reading the full report" else "skipped"});
}
