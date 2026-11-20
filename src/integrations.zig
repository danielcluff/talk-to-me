//! Agent integrations for the talktome CLI:
//!   talktome hook claude|codex|opencode   turn an agent's end-of-turn payload into speech
//!   talktome mcp [--app NAME]              stdio MCP server (speak, stop, list_voices)
//!   talktome install|uninstall TARGET      claude | codex | opencode | herdr
//!   talktome integrations [--json]         what is installed
//!
//! Hooks never fail the agent: errors go to stderr and the exit code is 0.

const std = @import("std");
const Io = std.Io;
const main = @import("main.zig");
const Ctx = main.Ctx;

const log = std.log.scoped(.integrations);

// ------------------------------------------------------------------ hooks

pub fn hook(ctx: *Ctx, rest: []const []const u8) !void {
    if (rest.len == 0) return main.fail(ctx, "usage: talktome hook claude|codex|opencode", .{});
    // a summarizer run by Talk to Me itself: its reply is not a report
    if (ctx.environ.get("TALKTOME_SUPPRESS") != null) {
        // Codex's chained notify program should still run
        if (main.eql(rest[0], "codex")) chainOnly(ctx, rest[1..]);
        return;
    }
    const which = rest[0];
    const result = if (main.eql(which, "claude"))
        hookClaude(ctx)
    else if (main.eql(which, "codex"))
        hookCodex(ctx, rest[1..])
    else if (main.eql(which, "opencode"))
        hookOpencode(ctx)
    else
        return main.fail(ctx, "unknown hook {s}", .{which});
    result catch |err| {
        // never fail the agent's turn
        const msg = std.fmt.allocPrint(ctx.arena, "talktome hook {s}: {t}\n", .{ which, err }) catch return;
        Io.File.stderr().writeStreamingAll(ctx.io, msg) catch {};
    };
}

fn readStdin(ctx: *Ctx) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var r = Io.File.stdin().reader(ctx.io, &buf);
    return r.interface.allocRemaining(ctx.arena, .limited(8 << 20));
}

/// Queue an agent's reply. `replace` drops an older unspoken reply from the
/// same session; the label is the project folder name.
fn speakReply(ctx: *Ctx, app: []const u8, cwd: []const u8, session: []const u8, text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    const label = if (cwd.len > 0) std.fs.path.basename(cwd) else "";
    const payload = try std.json.Stringify.valueAlloc(ctx.arena, .{
        .kind = "reply",
        .text = text,
        .format = "markdown",
        .policy = "replace",
        .source = .{ .app = app, .label = label, .session = session },
    }, .{});
    try main.ensureServer(ctx);
    _ = try main.request(ctx, .POST, "/v1/speak", payload);
}

fn hookClaude(ctx: *Ctx) !void {
    const In = struct {
        session_id: []const u8 = "",
        cwd: []const u8 = "",
        transcript_path: []const u8 = "",
        last_assistant_message: ?[]const u8 = null,
        stop_hook_active: bool = false,
    };
    const raw = try readStdin(ctx);
    const in = try std.json.parseFromSliceLeaky(In, ctx.arena, raw, .{ .ignore_unknown_fields = true });
    const text = in.last_assistant_message orelse
        (if (in.transcript_path.len > 0) try lastClaudeReply(ctx, in.transcript_path) else "");
    try speakReply(ctx, "claude-code", in.cwd, in.session_id, text);
}

/// Older Claude Code without last_assistant_message: the text blocks of the
/// assistant entries after the last real user prompt in the JSONL transcript.
fn lastClaudeReply(ctx: *Ctx, path: []const u8) ![]const u8 {
    const data = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(64 << 20));
    var turn: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, line, .{}) catch continue;
        if (v != .object) continue;
        const kind = (v.object.get("type") orelse continue);
        if (kind != .string) continue;
        const msg = v.object.get("message") orelse continue;
        if (msg != .object) continue;
        const content = msg.object.get("content") orelse continue;
        if (std.mem.eql(u8, kind.string, "user")) {
            // a tool result is not a new prompt
            const is_prompt = switch (content) {
                .string => true,
                .array => |arr| blk: {
                    for (arr.items) |item| {
                        if (item == .object) if (item.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "text")) break :blk true;
                    }
                    break :blk false;
                },
                else => false,
            };
            if (is_prompt) turn.clearRetainingCapacity();
        } else if (std.mem.eql(u8, kind.string, "assistant") and content == .array) {
            for (content.array.items) |item| {
                if (item != .object) continue;
                const t = item.object.get("type") orelse continue;
                const txt = item.object.get("text") orelse continue;
                if (t == .string and std.mem.eql(u8, t.string, "text") and txt == .string) {
                    if (turn.items.len > 0) try turn.appendSlice(ctx.arena, "\n\n");
                    try turn.appendSlice(ctx.arena, txt.string);
                }
            }
        }
    }
    return turn.items;
}

/// Run only the chained notify program of a Codex hook call.
fn chainOnly(ctx: *Ctx, args: []const []const u8) void {
    if (args.len == 0) return;
    const json = args[args.len - 1];
    var i: usize = 0;
    while (i < args.len - 1) : (i += 1) {
        if (main.eql(args[i], "--chain") and i + 1 < args.len - 1) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.appendSlice(ctx.arena, args[i + 1 .. args.len - 1]) catch return;
            argv.append(ctx.arena, json) catch return;
            _ = std.process.spawn(ctx.io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
            return;
        }
    }
}

/// Codex `notify`: argv ends with the JSON payload. `--chain PROG ARGS...`
/// (written by `talktome install codex`) runs the notify program that was
/// configured before, with the same payload.
fn hookCodex(ctx: *Ctx, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingPayload;
    const json = args[args.len - 1];
    var i: usize = 0;
    while (i < args.len - 1) : (i += 1) {
        if (main.eql(args[i], "--chain") and i + 1 < args.len - 1) {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(ctx.arena, args[i + 1 .. args.len - 1]);
            try argv.append(ctx.arena, json);
            // fire and forget: the chained program must not delay Codex
            _ = std.process.spawn(ctx.io, .{
                .argv = argv.items,
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |err| log.warn("chained notify failed: {t}", .{err});
            break;
        }
    }
    const In = struct {
        type: []const u8 = "",
        @"thread-id": []const u8 = "",
        cwd: []const u8 = "",
        @"last-assistant-message": ?[]const u8 = null,
    };
    const in = try std.json.parseFromSliceLeaky(In, ctx.arena, json, .{ .ignore_unknown_fields = true });
    if (!main.eql(in.type, "agent-turn-complete")) return;
    try speakReply(ctx, "codex", in.cwd, in.@"thread-id", in.@"last-assistant-message" orelse "");
}

fn hookOpencode(ctx: *Ctx) !void {
    const In = struct { session_id: []const u8 = "", cwd: []const u8 = "", text: []const u8 = "" };
    const in = try std.json.parseFromSliceLeaky(In, ctx.arena, try readStdin(ctx), .{ .ignore_unknown_fields = true });
    try speakReply(ctx, "opencode", in.cwd, in.session_id, in.text);
}

// ------------------------------------------------------------------ MCP

const mcp_tools =
    \\[
    \\  {"name": "speak",
    \\   "description": "Say something out loud to the user through Talk to Me (local text-to-speech). Use it for short updates the user should hear, such as a finished task or a question that needs them. Markdown is read naturally; code blocks are skipped.",
    \\   "inputSchema": {"type": "object", "properties": {
    \\     "text": {"type": "string", "description": "What to say."},
    \\     "interrupt": {"type": "boolean", "description": "Stop what is playing and say this now. Default: queue after it."},
    \\     "voice": {"type": "string", "description": "Optional voice name (see list_voices)."}
    \\   }, "required": ["text"]}},
    \\  {"name": "stop",
    \\   "description": "Stop speaking and clear the Talk to Me queue.",
    \\   "inputSchema": {"type": "object", "properties": {}}},
    \\  {"name": "list_voices",
    \\   "description": "List the voices of the active Talk to Me model.",
    \\   "inputSchema": {"type": "object", "properties": {}}}
    \\]
;

/// Model Context Protocol over stdio: one JSON-RPC message per line.
pub fn mcp(ctx: *Ctx, rest: []const []const u8) !void {
    var app: []const u8 = "mcp";
    if (rest.len >= 2 and main.eql(rest[0], "--app")) app = rest[1];

    var in_buf: [64 << 10]u8 = undefined;
    var reader = Io.File.stdin().reader(ctx.io, &in_buf);
    var out_buf: [16 << 10]u8 = undefined;
    var writer = Io.File.stdout().writer(ctx.io, &out_buf);
    const w = &writer.interface;

    var scratch: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer scratch.deinit();
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const msg = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{}) catch {
            try writeRpc(w, a, .null, null, .{ .code = -32700, .message = "parse error" });
            continue;
        };
        if (msg != .object) continue;
        const id = msg.object.get("id") orelse continue; // notification: no reply
        const method = if (msg.object.get("method")) |m| (if (m == .string) m.string else "") else "";
        const params = msg.object.get("params");
        var sub = ctx.*;
        sub.arena = a;

        if (main.eql(method, "initialize")) {
            const version = blk: {
                if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) break :blk v.string;
                break :blk "2025-06-18";
            };
            try writeRpc(w, a, id, .{
                .protocolVersion = version,
                .capabilities = .{ .tools = Empty{} },
                .serverInfo = .{ .name = "talk-to-me", .version = @import("server.zig").version },
            }, null);
        } else if (main.eql(method, "ping")) {
            try writeRpc(w, a, id, Empty{}, null);
        } else if (main.eql(method, "tools/list")) {
            const tools = try std.json.parseFromSliceLeaky(std.json.Value, a, mcp_tools, .{});
            try writeRpc(w, a, id, .{ .tools = tools }, null);
        } else if (main.eql(method, "tools/call")) {
            const text = callTool(&sub, app, params) catch |err| switch (err) {
                error.Reported => "Talk to Me is not available (is the app running?)",
                else => @errorName(err),
            };
            const failed = std.mem.startsWith(u8, text, "Talk to Me is not") or std.mem.indexOfScalar(u8, text, ' ') == null;
            try writeRpc(w, a, id, .{
                .content = &[_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = text }},
                .isError = failed,
            }, null);
        } else {
            try writeRpc(w, a, id, null, .{ .code = -32601, .message = "method not found" });
        }
    }
}

const RpcError = struct { code: i32, message: []const u8 };
/// Serializes as {} (an anonymous `.{}` is an empty tuple and becomes []).
const Empty = struct {};

fn writeRpc(w: *Io.Writer, a: std.mem.Allocator, id: std.json.Value, result: anytype, err: ?RpcError) !void {
    const line = if (err) |e|
        try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = e }, .{})
    else
        try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{});
    try w.writeAll(line);
    try w.writeAll("\n");
    try w.flush();
}

fn argString(params: ?std.json.Value, name: []const u8) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const args = p.object.get("arguments") orelse return null;
    if (args != .object) return null;
    const v = args.object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn argBool(params: ?std.json.Value, name: []const u8) bool {
    const p = params orelse return false;
    if (p != .object) return false;
    const args = p.object.get("arguments") orelse return false;
    if (args != .object) return false;
    const v = args.object.get(name) orelse return false;
    return v == .bool and v.bool;
}

fn callTool(ctx: *Ctx, app: []const u8, params: ?std.json.Value) ![]const u8 {
    const name = blk: {
        const p = params orelse return error.MissingTool;
        if (p != .object) return error.MissingTool;
        const n = p.object.get("name") orelse return error.MissingTool;
        if (n != .string) return error.MissingTool;
        break :blk n.string;
    };
    try main.ensureServer(ctx);
    if (main.eql(name, "speak")) {
        const text = argString(params, "text") orelse return "speak needs text";
        const payload = try std.json.Stringify.valueAlloc(ctx.arena, .{
            .kind = "message",
            .text = text,
            .voice = argString(params, "voice"),
            .policy = if (argBool(params, "interrupt")) "interrupt" else "queue",
            .source = .{ .app = app },
        }, .{ .emit_null_optional_fields = false });
        const body = try main.request(ctx, .POST, "/v1/speak", payload);
        const R = struct { job_id: ?[]const u8 = null, chunks: usize = 0, position: usize = 0, dropped: ?[]const u8 = null };
        const r = std.json.parseFromSliceLeaky(R, ctx.arena, body, .{ .ignore_unknown_fields = true }) catch R{};
        if (r.dropped) |why| return std.fmt.allocPrint(ctx.arena, "Not spoken: {s}.", .{why});
        if (r.position == 0) return std.fmt.allocPrint(ctx.arena, "Speaking now ({d} sentences).", .{r.chunks});
        return std.fmt.allocPrint(ctx.arena, "Queued at position {d} ({d} sentences).", .{ r.position, r.chunks });
    }
    if (main.eql(name, "stop")) {
        _ = try main.request(ctx, .POST, "/v1/player/stop", null);
        return "Stopped and cleared the queue.";
    }
    if (main.eql(name, "list_voices")) {
        const body = try main.request(ctx, .GET, "/v1/voices", null);
        const V = struct { name: []const u8 };
        const L = struct { model: []const u8, voices: []V };
        const list = try std.json.parseFromSliceLeaky(L, ctx.arena, body, .{ .ignore_unknown_fields = true });
        var text: std.ArrayList(u8) = .empty;
        try text.print(ctx.arena, "Voices of {s}:", .{list.model});
        for (list.voices) |v| try text.print(ctx.arena, " {s}", .{v.name});
        return text.items;
    }
    return std.fmt.allocPrint(ctx.arena, "Unknown tool {s}.", .{name});
}

// ------------------------------------------------------------------ install

pub const Target = enum { claude, codex, opencode, herdr };
const all_targets = [_]Target{ .claude, .codex, .opencode, .herdr };

fn home(ctx: *Ctx) ![]const u8 {
    return ctx.environ.get("HOME") orelse error.NoHome;
}

fn exists(ctx: *Ctx, path: []const u8) bool {
    Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

/// The CLI path written into agent configs: ~/.local/bin/talktome when
/// installed there (stable across app updates), else this executable.
fn cliPath(ctx: *Ctx) ![]const u8 {
    const linked = try std.fs.path.join(ctx.arena, &.{ try home(ctx), ".local", "bin", "talktome" });
    if (exists(ctx, linked)) return linked;
    return std.process.executablePathAlloc(ctx.io, ctx.arena);
}

/// Shipped integration files: <app>/Contents/Resources/integrations or
/// zig-out/share/talk-to-me/integrations, next to this binary.
fn sourceDir(ctx: *Ctx) ![]const u8 {
    const exe = try std.process.executablePathAlloc(ctx.io, ctx.arena);
    const dir = std.fs.path.dirname(exe) orelse ".";
    const candidates = [_][]const u8{
        try std.fs.path.join(ctx.arena, &.{ dir, "integrations" }),
        try std.fs.path.join(ctx.arena, &.{ dir, "..", "share", "talk-to-me", "integrations" }),
    };
    for (candidates) |c| if (exists(ctx, c)) return c;
    return main.fail(ctx, "integration files not found next to {s}", .{exe});
}

fn readFile(ctx: *Ctx, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(4 << 20));
}

fn writeFile(ctx: *Ctx, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(ctx.io, d);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data });
}

/// Copy a shipped file, replacing the bare `talktome` command / placeholder
/// with the absolute CLI path.
fn copyWithCli(ctx: *Ctx, src: []const u8, dst: []const u8, cli: []const u8) !void {
    var data = try readFile(ctx, src);
    data = try std.mem.replaceOwned(u8, ctx.arena, data, "__TALKTOME__", cli);
    const quoted_cli = try std.json.Stringify.valueAlloc(ctx.arena, cli, .{});
    data = try std.mem.replaceOwned(u8, ctx.arena, data, "\"command\": \"talktome\"", try std.fmt.allocPrint(ctx.arena, "\"command\": {s}", .{quoted_cli}));
    try writeFile(ctx, dst, data);
}

fn run(ctx: *Ctx, argv: []const []const u8) !bool {
    var child = std.process.spawn(ctx.io, .{ .argv = argv, .stdin = .ignore }) catch return false;
    const term = try child.wait(ctx.io);
    return term.success();
}

pub fn status(ctx: *Ctx, target: Target) !bool {
    const h = try home(ctx);
    return switch (target) {
        .claude => blk: {
            const f = try std.fs.path.join(ctx.arena, &.{ h, ".claude", "plugins", "installed_plugins.json" });
            const data = readFile(ctx, f) catch break :blk false;
            break :blk std.mem.indexOf(u8, data, "\"talk-to-me@talk-to-me\"") != null;
        },
        .codex => blk: {
            const data = readFile(ctx, try codexConfig(ctx)) catch break :blk false;
            const line = codexNotifyLine(data) orelse break :blk false;
            break :blk std.mem.indexOf(u8, line.text, "\"hook\", \"codex\"") != null;
        },
        .opencode => exists(ctx, try std.fs.path.join(ctx.arena, &.{ h, ".config", "opencode", "plugins", "talk-to-me.ts" })),
        .herdr => exists(ctx, try std.fs.path.join(ctx.arena, &.{ h, ".config", "herdr-app", "mods", "talk-to-me", "main.js" })),
    };
}

/// Whether the agent itself seems to be installed (its config folder exists).
fn present(ctx: *Ctx, target: Target) !bool {
    const h = try home(ctx);
    const dir = switch (target) {
        .claude => ".claude",
        .codex => ".codex",
        .opencode => ".config/opencode",
        .herdr => ".config/herdr-app",
    };
    return exists(ctx, try std.fs.path.join(ctx.arena, &.{ h, dir }));
}

pub fn integrationsCmd(ctx: *Ctx, rest: []const []const u8) !void {
    const json = rest.len > 0 and main.eql(rest[0], "--json");
    if (json) {
        var w: Io.Writer.Allocating = .init(ctx.arena);
        try w.writer.writeAll("{");
        for (all_targets, 0..) |t, i| {
            if (i > 0) try w.writer.writeAll(",");
            try w.writer.print("\"{s}\":{{\"installed\":{},\"present\":{}}}", .{ @tagName(t), try status(ctx, t), try present(ctx, t) });
        }
        try w.writer.writeAll("}\n");
        return main.out(ctx.io, w.written());
    }
    for (all_targets) |t| {
        try main.outf(ctx, "{s:<9} {s}\n", .{ @tagName(t), if (try status(ctx, t)) "installed" else if (try present(ctx, t)) "not installed" else "not found" });
    }
}

pub fn installCmd(ctx: *Ctx, rest: []const []const u8, install: bool) !void {
    if (rest.len == 0) return main.fail(ctx, "usage: talktome {s} claude|codex|opencode|herdr", .{if (install) "install" else "uninstall"});
    const target = std.meta.stringToEnum(Target, rest[0]) orelse return main.fail(ctx, "unknown target {s}", .{rest[0]});
    switch (target) {
        .claude => try claude(ctx, install),
        .codex => try codex(ctx, install),
        .opencode => try opencode(ctx, install),
        .herdr => try herdr(ctx, install),
    }
}

fn claude(ctx: *Ctx, install: bool) !void {
    if (!install) {
        _ = try run(ctx, &.{ "claude", "plugin", "uninstall", "talk-to-me@talk-to-me" });
        _ = try run(ctx, &.{ "claude", "plugin", "marketplace", "remove", "talk-to-me" });
        return main.out(ctx.io, "Claude Code: plugin removed\n");
    }
    // a stable copy in the support dir, so the marketplace survives app moves
    const src = try sourceDir(ctx);
    const dst = try std.fs.path.join(ctx.arena, &.{ ctx.paths.root, "integrations" });
    const cli = try cliPath(ctx);
    const files = [_][]const u8{
        ".claude-plugin/marketplace.json",
        "claude-code/.claude-plugin/plugin.json",
        "claude-code/hooks/hooks.json",
        "claude-code/.mcp.json",
    };
    for (files) |f| {
        try copyWithCli(ctx, try std.fs.path.join(ctx.arena, &.{ src, f }), try std.fs.path.join(ctx.arena, &.{ dst, f }), cli);
    }
    _ = try run(ctx, &.{ "claude", "plugin", "marketplace", "remove", "talk-to-me" });
    if (!try run(ctx, &.{ "claude", "plugin", "marketplace", "add", dst }))
        return main.fail(ctx, "claude plugin marketplace add failed (is the claude CLI on PATH?)", .{});
    if (!try run(ctx, &.{ "claude", "plugin", "install", "talk-to-me@talk-to-me" }))
        return main.fail(ctx, "claude plugin install failed", .{});
    try main.out(ctx.io, "Claude Code: plugin installed. Restart open Claude Code sessions to load it.\n");
}

fn codexConfig(ctx: *Ctx) ![]const u8 {
    if (ctx.environ.get("CODEX_HOME")) |ch| return std.fs.path.join(ctx.arena, &.{ ch, "config.toml" });
    return std.fs.path.join(ctx.arena, &.{ try home(ctx), ".codex", "config.toml" });
}

const Line = struct { start: usize, end: usize, text: []const u8 };

/// The top-level `notify = [...]` line (before the first [table]), if any.
fn codexNotifyLine(data: []const u8) ?Line {
    var pos: usize = 0;
    while (pos < data.len) {
        const end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..end];
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "[")) return null;
        if (std.mem.startsWith(u8, t, "notify") and std.mem.indexOfScalar(u8, t, '=') != null) {
            const rest = std.mem.trimStart(u8, t["notify".len..], " \t");
            if (rest.len > 0 and rest[0] == '=') return .{ .start = pos, .end = end, .text = line };
        }
        pos = end + 1;
    }
    return null;
}

/// The quoted items of a TOML string array, verbatim (with their quotes).
fn tomlItems(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    const open = std.mem.indexOfScalar(u8, line, '[') orelse return items.items;
    var i = open + 1;
    while (i < line.len) : (i += 1) {
        const q = line[i];
        if (q != '"' and q != '\'') continue;
        var j = i + 1;
        while (j < line.len and line[j] != q) : (j += 1) {
            if (q == '"' and line[j] == '\\') j += 1;
        }
        try items.append(a, line[i .. @min(j, line.len - 1) + 1]);
        i = j;
    }
    return items.items;
}

fn codex(ctx: *Ctx, install: bool) !void {
    const path = try codexConfig(ctx);
    const data = readFile(ctx, path) catch |err| switch (err) {
        error.FileNotFound => @as([]const u8, ""),
        else => return err,
    };
    const cli_json = try std.json.Stringify.valueAlloc(ctx.arena, try cliPath(ctx), .{});
    const line = codexNotifyLine(data);
    const ours = if (line) |l| std.mem.indexOf(u8, l.text, "\"hook\", \"codex\"") != null else false;

    var new_line: ?[]const u8 = null; // null: remove the line
    if (install) {
        if (ours) return main.out(ctx.io, "Codex: already installed\n");
        if (line) |l| {
            // keep the existing notify program by chaining it
            const old = try tomlItems(ctx.arena, l.text);
            const joined = try std.mem.join(ctx.arena, ", ", old);
            new_line = try std.fmt.allocPrint(ctx.arena, "notify = [{s}, \"hook\", \"codex\", \"--chain\", {s}]", .{ cli_json, joined });
        } else {
            new_line = try std.fmt.allocPrint(ctx.arena, "notify = [{s}, \"hook\", \"codex\"]", .{cli_json});
        }
    } else {
        const l = line orelse return main.out(ctx.io, "Codex: not installed\n");
        if (!ours) return main.out(ctx.io, "Codex: not installed\n");
        const items = try tomlItems(ctx.arena, l.text);
        for (items, 0..) |it, k| {
            if (main.eql(it, "\"--chain\"")) {
                new_line = try std.fmt.allocPrint(ctx.arena, "notify = [{s}]", .{try std.mem.join(ctx.arena, ", ", items[k + 1 ..])});
                break;
            }
        }
    }

    // back up once, then write
    if (data.len > 0) {
        const backup = try std.fmt.allocPrint(ctx.arena, "{s}.talktome-backup", .{path});
        if (!exists(ctx, backup)) try writeFile(ctx, backup, data);
    }
    var out: std.ArrayList(u8) = .empty;
    if (line) |l| {
        try out.appendSlice(ctx.arena, data[0..l.start]);
        if (new_line) |nl| try out.appendSlice(ctx.arena, nl);
        const after = if (new_line == null and l.end < data.len) l.end + 1 else l.end;
        try out.appendSlice(ctx.arena, data[after..]);
    } else {
        try out.appendSlice(ctx.arena, new_line.?);
        try out.appendSlice(ctx.arena, "\n");
        try out.appendSlice(ctx.arena, data);
    }
    try writeFile(ctx, path, out.items);
    try main.outf(ctx, "Codex: {s} ({s})\n", .{ if (install) "installed" else "removed", path });
}

fn opencode(ctx: *Ctx, install: bool) !void {
    const dst = try std.fs.path.join(ctx.arena, &.{ try home(ctx), ".config", "opencode", "plugins", "talk-to-me.ts" });
    if (!install) {
        Io.Dir.cwd().deleteFile(ctx.io, dst) catch {};
        return main.out(ctx.io, "OpenCode: plugin removed\n");
    }
    const src = try std.fs.path.join(ctx.arena, &.{ try sourceDir(ctx), "opencode", "talk-to-me.ts" });
    try copyWithCli(ctx, src, dst, try cliPath(ctx));
    try main.outf(ctx, "OpenCode: plugin installed ({s}). Restart OpenCode to load it.\n", .{dst});
}

/// herdr: the mod, plus a personal copy of the shipped `main` layout with the
/// Talk to Me bar beside the status bar. Shipped layouts are read-only, so
/// herdr can't dock a new mod into `main` by itself.
fn herdr(ctx: *Ctx, install: bool) !void {
    const herdr_home = try std.fs.path.join(ctx.arena, &.{ try home(ctx), ".config", "herdr-app" });
    const dst = try std.fs.path.join(ctx.arena, &.{ herdr_home, "mods", "talk-to-me" });
    const layout = try std.fs.path.join(ctx.arena, &.{ herdr_home, "layouts", "talk-to-me.json" });
    if (!install) {
        // back to herdr's own layout first, so the window never shows a missing mod
        _ = try runQuiet(ctx, &.{ "herdr-app", "do", "layout.switch", "{\"name\":\"main\"}" });
        Io.Dir.cwd().deleteFile(ctx.io, layout) catch {};
        Io.Dir.cwd().deleteTree(ctx.io, dst) catch {};
        return main.out(ctx.io, "herdr: mod and layout removed\n");
    }
    const src = try std.fs.path.join(ctx.arena, &.{ try sourceDir(ctx), "herdr", "talk-to-me" });
    for ([_][]const u8{ "main.js", "mod.json" }) |f| {
        try writeFile(ctx, try std.fs.path.join(ctx.arena, &.{ dst, f }), try readFile(ctx, try std.fs.path.join(ctx.arena, &.{ src, f })));
    }
    if (!try run(ctx, &.{ "herdr-app", "check", dst })) try main.out(ctx.io, "herdr: installed, but `herdr-app check` reported a problem\n");

    const base = readFile(ctx, try std.fs.path.join(ctx.arena, &.{ herdr_home, "layouts", "main.json" })) catch {
        return main.outf(ctx, "herdr: mod installed ({s}); open herdr once, then install again to add the bar\n", .{dst});
    };
    var tree = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, base, .{});
    if (!try addBar(ctx.arena, &tree)) {
        return main.outf(ctx, "herdr: mod installed ({s}), but herdr's layout has no status bar to sit beside\n", .{dst});
    }
    try writeFile(ctx, layout, try std.json.Stringify.valueAlloc(ctx.arena, tree, .{ .whitespace = .indent_2 }));
    const switched = try runQuiet(ctx, &.{ "herdr-app", "do", "layout.switch", "{\"name\":\"talk-to-me\"}" });
    try main.outf(ctx, "herdr: mod installed; layout \"talk-to-me\" adds the bar at the bottom{s}\n", .{
        if (switched) " (now shown)" else " (pick it with ctrl-shift-l)",
    });
}

/// Replace the node with id "status" by a row: the status bar, then the
/// Talk to Me bar on the right.
fn addBar(a: std.mem.Allocator, v: *std.json.Value) !bool {
    if (v.* != .object) return false;
    const obj = &v.object;
    if (obj.get("id")) |id| if (id == .string and std.mem.eql(u8, id.string, "status")) {
        const size = obj.get("size");
        var status_bar = v.*;
        _ = status_bar.object.orderedRemove("size");
        var bar: std.json.ObjectMap = .empty;
        try bar.put(a, "id", .{ .string = "talk-to-me" });
        try bar.put(a, "type", .{ .string = "block" });
        var bar_size: std.json.ObjectMap = .empty;
        try bar_size.put(a, "px", .{ .integer = 380 });
        try bar.put(a, "size", .{ .object = bar_size });
        var content: std.json.ObjectMap = .empty;
        try content.put(a, "mod", .{ .string = "talk-to-me" });
        try bar.put(a, "content", .{ .object = content });

        var children = std.json.Array.init(a);
        try children.append(status_bar);
        try children.append(.{ .object = bar });
        var row: std.json.ObjectMap = .empty;
        try row.put(a, "id", .{ .string = "status-row" });
        try row.put(a, "type", .{ .string = "row" });
        if (size) |sz| try row.put(a, "size", sz);
        try row.put(a, "children", .{ .array = children });
        v.* = .{ .object = row };
        return true;
    };
    if (obj.getPtr("children")) |ch| if (ch.* == .array) {
        for (ch.array.items) |*child| if (try addBar(a, child)) return true;
    };
    return false;
}

/// Run without showing output; false if it fails or can't start (e.g. herdr isn't running).
fn runQuiet(ctx: *Ctx, argv: []const []const u8) !bool {
    var child = std.process.spawn(ctx.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(ctx.io) catch return false;
    return term.success();
}
