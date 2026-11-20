//! Recognise the hidden turn Codex runs to name a thread.

const std = @import("std");

/// Codex names a new thread with a hidden turn of its own, which still fires
/// `notify` as "agent-turn-complete". Its reply is a bare JSON object such as
/// {"title":"...","description":"..."}: not something the user asked for.
pub fn isTitleTurn(a: std.mem.Allocator, msg: []const u8) bool {
    const trimmed = std.mem.trim(u8, msg, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{') return false;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{}) catch return false;
    if (parsed != .object) return false;
    const obj = parsed.object;
    if (obj.get("title") == null) return false;
    for (obj.keys()) |k| {
        if (!std.mem.eql(u8, k, "title") and !std.mem.eql(u8, k, "description") and !std.mem.eql(u8, k, "summary")) return false;
    }
    return true;
}

test "Codex title turns are recognised" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(isTitleTurn(a, "{\"title\":\"Review project\",\"description\":\"Thorough review\"}"));
    try std.testing.expect(isTitleTurn(a, " {\"title\":\"Mood board\"}\n"));
    try std.testing.expect(!isTitleTurn(a, "The mood board is ready."));
    try std.testing.expect(!isTitleTurn(a, "{\"title\":\"x\",\"items\":[1]}"));
    try std.testing.expect(!isTitleTurn(a, "{not json"));
}
