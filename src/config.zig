//! Paths, settings and the API token.
//!
//! Everything lives under ~/Library/Application Support/TalkToMe (or
//! $TALKTOME_HOME, used by tests):
//!   settings.json   user settings (missing keys take defaults)
//!   token           bearer token for the local API, mode 0600
//!   models/<id>/    downloaded model files

const std = @import("std");
const Io = std.Io;
const markdown = @import("text/markdown.zig");

pub const default_port: u16 = 9932;

pub const Settings = struct {
    model: []const u8 = "kokoro",
    /// empty: the model's default voice
    voice: []const u8 = "",
    speed: f32 = 1.0,
    port: u16 = default_port,
    idle_unload_minutes: u32 = 15,
    code_blocks: markdown.CodeBlocks = .announce,
    tables: markdown.Tables = .announce,
    /// identical text from the same source within this window is dropped
    dedupe_seconds: u32 = 30,
};

pub const Paths = struct {
    root: []const u8,
    settings: []const u8,
    token: []const u8,
    models: []const u8,
    logs: []const u8,

    pub fn init(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !Paths {
        const root = if (environ.get("TALKTOME_HOME")) |h|
            try arena.dupe(u8, h)
        else blk: {
            const home = environ.get("HOME") orelse return error.NoHome;
            break :blk try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "TalkToMe" });
        };
        const logs = if (environ.get("TALKTOME_HOME") != null)
            try std.fs.path.join(arena, &.{ root, "logs" })
        else
            try std.fs.path.join(arena, &.{ environ.get("HOME").?, "Library", "Logs", "TalkToMe" });
        return .{
            .root = root,
            .settings = try std.fs.path.join(arena, &.{ root, "settings.json" }),
            .token = try std.fs.path.join(arena, &.{ root, "token" }),
            .models = try std.fs.path.join(arena, &.{ root, "models" }),
            .logs = logs,
        };
    }

    pub fn modelDir(p: Paths, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ p.models, id });
    }
};

/// Settings plus the arena that owns their strings.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    value: Settings,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

pub fn loadSettings(gpa: std.mem.Allocator, io: Io, paths: Paths) !Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const data = Io.Dir.cwd().readFileAlloc(io, paths.settings, a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .value = .{} },
        else => return err,
    };
    const value = std.json.parseFromSliceLeaky(Settings, a, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("settings.json is invalid ({t}), using defaults", .{err});
        return .{ .arena = arena, .value = .{} };
    };
    return .{ .arena = arena, .value = value };
}

pub fn saveSettings(gpa: std.mem.Allocator, io: Io, paths: Paths, s: Settings) !void {
    try Io.Dir.cwd().createDirPath(io, paths.root);
    const json = try std.json.Stringify.valueAlloc(gpa, s, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{paths.settings});
    defer gpa.free(tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = json });
    try Io.Dir.rename(.cwd(), tmp, .cwd(), paths.settings, io);
}

/// Read the API token, creating it (32 random bytes, hex, mode 0600) on first use.
pub fn loadOrCreateToken(arena: std.mem.Allocator, io: Io, paths: Paths) ![]const u8 {
    if (Io.Dir.cwd().readFileAlloc(io, paths.token, arena, .limited(256))) |data| {
        const t = std.mem.trim(u8, data, " \r\n\t");
        if (t.len >= 32) return t;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try Io.Dir.cwd().createDirPath(io, paths.root);
    var raw: [32]u8 = undefined;
    try io.randomSecure(&raw);
    const hex = try std.fmt.allocPrint(arena, "{x}", .{&raw});
    const file = try Io.Dir.cwd().createFile(io, paths.token, .{
        .permissions = .fromMode(0o600),
        .truncate = true,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, hex);
    return hex;
}

/// Read the token without creating it (clients).
pub fn readToken(arena: std.mem.Allocator, io: Io, paths: Paths) ![]const u8 {
    const data = try Io.Dir.cwd().readFileAlloc(io, paths.token, arena, .limited(256));
    return std.mem.trim(u8, data, " \r\n\t");
}
