//! Briefings: turn an agent's end-of-turn report into a short spoken summary.
//!
//! Backends share one prompt and return plain text:
//!   codex     `codex exec … -o <file> -`  (prompt on stdin, answer in the file)
//!   claude    `claude -p --tools "" …`    (prompt on stdin, answer on stdout)
//!   opencode  `opencode run [-m …] <prompt>` (answer on stdout)
//!   ollama    POST <url>/api/chat (through curl, for its --max-time)
//!   local     an in-process model (engine; Stage C)
//!
//! Every CLI runs in an empty work folder, in its own process group (the
//! timeout kills the group, so a grandchild can't hold the output open),
//! with no tools, and with
//! TALKTOME_SUPPRESS=1 so our own agent hooks stand down: the summarizer is an
//! agent too, and its reply must not come back as a new report to brief.

const std = @import("std");
const Io = std.Io;

pub const Backend = enum { codex, claude, opencode, ollama, local };

pub const Config = struct {
    backend: Backend = .codex,
    /// model name for the backend; empty = the tool's default
    model: []const u8 = "",
    ollama_url: []const u8 = "http://127.0.0.1:11434",
    timeout_seconds: u32 = 30,
};

pub const min_timeout_seconds = 3;
pub const max_timeout_seconds = 300;

pub fn clampTimeout(seconds: u32) u32 {
    return std.math.clamp(seconds, min_timeout_seconds, max_timeout_seconds);
}

/// An Ollama address must be a plain http(s) URL: it receives every report.
pub fn validOllamaUrl(url: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else
        return false;
    if (rest.len == 0 or rest.len > 200) return false;
    for (rest) |ch| if (ch <= ' ' or ch == '@' or ch == '"' or ch == '\\' or ch >= 0x7f) return false;
    return true;
}

pub const prompt_intro =
    \\You turn a coding agent's end-of-turn report into a short spoken briefing for the person who asked for the work.
    \\Write 1 to 3 plain sentences, at most 60 words. No markdown, lists, code, file paths or URLs.
    \\Lead with the outcome. Then mention anything that failed or is blocked, and any question the agent is asking the person.
    \\Write it to be read aloud. Don't start with "The agent" and don't add a greeting.
    \\
    \\Report:
    \\
;

pub fn buildPrompt(a: std.mem.Allocator, report: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ prompt_intro, report });
}

pub const Env = struct {
    home: []const u8,
    /// a folder with nothing in it, so CLIs pick up no project instructions
    workdir: []const u8,
};

/// Summarize `report`. Returns the summary (allocated with `a`), or an error;
/// the caller falls back to the report's first paragraph.
pub fn summarize(a: std.mem.Allocator, io: Io, env: Env, cfg: Config, report: []const u8) ![]const u8 {
    const prompt = try buildPrompt(a, report);
    const raw = switch (cfg.backend) {
        .codex => try runCodex(a, io, env, cfg, prompt),
        .claude => try runCli(a, io, env, cfg, "claude", prompt, true),
        .opencode => try runCli(a, io, env, cfg, "opencode", prompt, false),
        .ollama => try runOllama(a, io, env, cfg, prompt),
        .local => return error.LocalBackendUnavailable,
    };
    const cleaned = try clean(a, raw);
    if (cleaned.len == 0) return error.EmptySummary;
    return cleaned;
}

/// Strip <think> blocks, ANSI escapes, markdown emphasis and surrounding
/// whitespace; collapse lines into one paragraph.
pub fn clean(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var t = text;
    if (std.mem.indexOf(u8, t, "</think>")) |i| t = t[i + "</think>".len ..];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var prev_space = true;
    while (i < t.len) : (i += 1) {
        const ch = t[i];
        if (ch == 0x1b) { // ANSI escape: skip to the final byte
            i += 1;
            if (i < t.len and t[i] == '[') {
                while (i + 1 < t.len and !(t[i + 1] >= '@' and t[i + 1] <= '~')) i += 1;
                i += 1;
            }
            continue;
        }
        if (ch == '*' or ch == '`' or ch == '#') continue;
        const space = ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t';
        if (space) {
            if (!prev_space) try out.append(a, ' ');
        } else {
            try out.append(a, ch);
        }
        prev_space = space;
    }
    return std.mem.trim(u8, out.items, " ");
}

/// The report's first paragraph, for when summarizing fails.
pub fn firstParagraph(report: []const u8) []const u8 {
    var rest = std.mem.trim(u8, report, " \t\r\n");
    // skip a leading markdown heading line
    while (rest.len > 0 and rest[0] == '#') {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        rest = std.mem.trimStart(u8, rest[nl + 1 ..], " \t\r\n");
    }
    const end = std.mem.indexOf(u8, rest, "\n\n") orelse rest.len;
    return @import("text/utf8.zig").prefix(rest[0..end], 400);
}

// ------------------------------------------------------------------ tools

const search_dirs = [_][]const u8{ ".local/bin", ".opencode/bin", ".bun/bin", ".npm-global/bin", ".cargo/bin" };
const system_dirs = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" };

/// PATH for child processes: the usual install folders first, since an app
/// started from Finder gets a minimal PATH.
fn childPath(a: std.mem.Allocator, home: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (search_dirs) |d| try parts.append(a, try std.fs.path.join(a, &.{ home, d }));
    for (system_dirs) |d| try parts.append(a, d);
    try parts.append(a, "/usr/sbin");
    try parts.append(a, "/sbin");
    return std.mem.join(a, ":", parts.items);
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Find a CLI: the install folders, then the login shell's PATH.
pub fn findTool(a: std.mem.Allocator, io: Io, home: []const u8, name: []const u8) ![]const u8 {
    for (search_dirs) |d| {
        const p = try std.fs.path.join(a, &.{ home, d, name });
        if (exists(io, p)) return p;
    }
    for (system_dirs) |d| {
        const p = try std.fs.path.join(a, &.{ d, name });
        if (exists(io, p)) return p;
    }
    const r = std.process.run(a, io, .{
        .argv = &.{ "/bin/zsh", "-lc", try std.fmt.allocPrint(a, "command -v {s}", .{name}) },
    }) catch return error.ToolNotFound;
    const found = std.mem.trim(u8, r.stdout, " \r\n");
    if (found.len > 0 and found[0] == '/' and exists(io, found)) return found;
    return error.ToolNotFound;
}

fn childEnv(a: std.mem.Allocator, env: Env) !*std.process.Environ.Map {
    const m = try a.create(std.process.Environ.Map);
    m.* = .init(a);
    try m.put("HOME", env.home);
    try m.put("PATH", try childPath(a, env.home));
    try m.put("TALKTOME_SUPPRESS", "1");
    try m.put("NO_COLOR", "1");
    try m.put("TERM", "dumb");
    inline for (.{ "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL" }) |k| {
        if (std.c.getenv(k)) |v| try m.put(k, std.mem.span(v));
    }
    return m;
}

const Killer = struct {
    io: Io,
    /// the child's pid, which is also its process group id
    pid: std.process.Child.Id,
    seconds: u32,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    fn run(k: *Killer) void {
        const limit: u64 = @as(u64, clampTimeout(k.seconds)) * 1000;
        var waited: u64 = 0;
        while (!k.done.load(.acquire)) : (waited += 100) {
            if (waited >= limit) {
                k.fired.store(true, .release);
                killGroup(k.pid);
                return;
            }
            k.io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }
};

/// Kill a whole process group: the CLI and anything it started.
fn killGroup(pid: std.process.Child.Id) void {
    std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
}

/// Run argv with `stdin_data`, return stdout; killed after the timeout.
fn runWithTimeout(a: std.mem.Allocator, io: Io, env: Env, argv: []const []const u8, stdin_data: ?[]const u8, seconds: u32) ![]const u8 {
    return runWithTimeoutEnv(a, io, env, try childEnv(a, env), argv, stdin_data, seconds);
}

fn runWithTimeoutEnv(a: std.mem.Allocator, io: Io, env: Env, environ: *std.process.Environ.Map, argv: []const []const u8, stdin_data: ?[]const u8, seconds: u32) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, env.workdir);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = env.workdir },
        .environ_map = environ,
        .stdin = if (stdin_data != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0, // a group of its own, killed as one
    });
    var killer: Killer = .{ .io = io, .pid = child.id.?, .seconds = seconds };
    const watchdog = try std.Thread.spawn(.{}, Killer.run, .{&killer});
    defer {
        killer.done.store(true, .release);
        watchdog.join();
        killGroup(killer.pid); // leftovers (servers, helpers) go too
    }
    if (stdin_data) |data| {
        if (child.stdin) |f| {
            f.writeStreamingAll(io, data) catch {};
            f.close(io);
            child.stdin = null;
        }
    }
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    const out = r.interface.allocRemaining(a, .limited(1 << 20)) catch "";
    const term = child.wait(io) catch return error.ToolFailed;
    if (killer.fired.load(.acquire)) return error.Timeout;
    if (!term.success()) return error.ToolFailed;
    return out;
}

fn runCodex(a: std.mem.Allocator, io: Io, env: Env, cfg: Config, prompt: []const u8) ![]const u8 {
    const tool = try findTool(a, io, env.home, "codex");
    const out_file = try std.fs.path.join(a, &.{ env.workdir, "codex-last-message.txt" });
    Io.Dir.cwd().deleteFile(io, out_file) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ tool, "exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never" });
    if (cfg.model.len > 0) try argv.appendSlice(a, &.{ "-m", cfg.model });
    try argv.appendSlice(a, &.{ "-o", out_file, "-" });
    _ = try runWithTimeout(a, io, env, argv.items, prompt, cfg.timeout_seconds);
    return Io.Dir.cwd().readFileAlloc(io, out_file, a, .limited(1 << 20)) catch error.ToolFailed;
}

fn runCli(a: std.mem.Allocator, io: Io, env: Env, cfg: Config, name: []const u8, prompt: []const u8, use_stdin: bool) ![]const u8 {
    const tool = try findTool(a, io, env.home, name);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, tool);
    if (std.mem.eql(u8, name, "claude")) {
        try argv.appendSlice(a, &.{ "-p", "--tools", "", "--no-session-persistence", "--disable-slash-commands" });
        if (cfg.model.len > 0) try argv.appendSlice(a, &.{ "--model", cfg.model });
    } else { // opencode
        // a private server (so this config applies) whose agent may not use tools
        try argv.appendSlice(a, &.{ "run", "--standalone" });
        if (cfg.model.len > 0) try argv.appendSlice(a, &.{ "-m", cfg.model });
        try argv.append(a, prompt);
    }
    const environ = try childEnv(a, env);
    if (!use_stdin) {
        try environ.put("OPENCODE_CONFIG_CONTENT", opencode_no_tools);
        try environ.put("OPENCODE_DISABLE_PROJECT_CONFIG", "1");
        try environ.put("OPENCODE_DISABLE_CLAUDE_CODE", "1");
    }
    return runWithTimeoutEnv(a, io, env, environ, argv.items, if (use_stdin) prompt else null, cfg.timeout_seconds);
}

/// OpenCode allows every tool by default, and a report can quote untrusted
/// text. Deny tools in both the v2 rule format and the older one.
const opencode_no_tools =
    \\{"permissions":[{"action":"*","resource":"*","effect":"deny"}],
    \\ "policies":[{"action":"tool.use","resource":"*","effect":"deny"},{"action":"mcp.use","resource":"*","effect":"deny"}],
    \\ "permission":{"*":"deny"}}
;

fn runOllama(a: std.mem.Allocator, io: Io, env: Env, cfg: Config, prompt: []const u8) ![]const u8 {
    if (cfg.model.len == 0) return error.ModelRequired;
    if (!validOllamaUrl(cfg.ollama_url)) return error.BadOllamaUrl;
    const payload = try std.json.Stringify.valueAlloc(a, .{
        .model = cfg.model,
        .stream = false,
        .think = false,
        .messages = &[_]struct { role: []const u8, content: []const u8 }{.{ .role = "user", .content = prompt }},
        .options = .{ .temperature = 0.2 },
    }, .{});
    const url = try std.fmt.allocPrint(a, "{s}/api/chat", .{std.mem.trimEnd(u8, cfg.ollama_url, "/")});
    // curl, not std.http.Client: --max-time bounds the whole exchange, so a
    // server that accepts and never answers can't block later briefings
    const max_time = try std.fmt.allocPrint(a, "{d}", .{clampTimeout(cfg.timeout_seconds)});
    const body = runWithTimeout(a, io, env, &.{
        "/usr/bin/curl",  "-sS",            "--fail",         "--proto", "=http,https", "--max-time", max_time,
        "-H",             "content-type: application/json", "--data-binary", "@-", url,
    }, payload, cfg.timeout_seconds + 2) catch |err| switch (err) {
        error.Timeout => return err,
        else => return error.OllamaFailed,
    };
    const R = struct { message: struct { content: []const u8 } };
    const r = std.json.parseFromSliceLeaky(R, a, body, .{ .ignore_unknown_fields = true }) catch return error.OllamaFailed;
    return r.message.content;
}

// ---------------------------------------------------------------- tests

test "clean strips think blocks, ansi and markdown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try clean(arena.allocator(), "<think>hmm</think>\n\x1b[1m**Done.**\x1b[0m Tests\n pass.\n");
    try std.testing.expectEqualStrings("Done. Tests pass.", out);
}

test "ollama urls" {
    try std.testing.expect(validOllamaUrl("http://127.0.0.1:11434"));
    try std.testing.expect(validOllamaUrl("https://gpu-box.local:11434/"));
    try std.testing.expect(!validOllamaUrl("file:///etc/passwd"));
    try std.testing.expect(!validOllamaUrl("http://user@evil.example"));
    try std.testing.expect(!validOllamaUrl("http://a b"));
    try std.testing.expect(!validOllamaUrl("http://"));
}

test "timeouts are bounded" {
    try std.testing.expectEqual(@as(u32, 3), clampTimeout(0));
    try std.testing.expectEqual(@as(u32, 300), clampTimeout(std.math.maxInt(u32)));
}

test "first paragraph skips a heading" {
    try std.testing.expectEqualStrings("I fixed the parser.", firstParagraph("# Summary\n\nI fixed the parser.\n\nMore."));
}
