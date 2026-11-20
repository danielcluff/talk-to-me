//! Pronunciation dictionary: whole-word replacements applied to speakable
//! text before it is split into sentences (e.g. "kubectl" → "cube control",
//! "SQL" → "sequel", "C++" → "C plus plus").
//!
//! A match must start and end at a word boundary: the characters around it
//! are not letters, digits or '_'. Matching is ASCII case-insensitive unless
//! the entry says otherwise. The longest entry wins when several match at the
//! same position.

const std = @import("std");

pub const Entry = struct {
    from: []const u8,
    to: []const u8,
    case_sensitive: bool = false,
};

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

fn matchesAt(text: []const u8, i: usize, e: Entry) bool {
    if (e.from.len == 0 or i + e.from.len > text.len) return false;
    const piece = text[i .. i + e.from.len];
    const same = if (e.case_sensitive) std.mem.eql(u8, piece, e.from) else std.ascii.eqlIgnoreCase(piece, e.from);
    if (!same) return false;
    // boundaries only matter on the sides where the entry itself is a word character
    if (isWordChar(e.from[0]) and i > 0 and isWordChar(text[i - 1])) return false;
    const end = i + e.from.len;
    if (isWordChar(e.from[e.from.len - 1]) and end < text.len and isWordChar(text[end])) return false;
    return true;
}

/// Returns `text` unchanged (no allocation) when nothing matches.
pub fn apply(a: std.mem.Allocator, text: []const u8, entries: []const Entry) ![]const u8 {
    if (entries.len == 0) return text;
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    var i: usize = 0;
    var copied: usize = 0;
    while (i < text.len) {
        var best: ?Entry = null;
        for (entries) |e| {
            if (matchesAt(text, i, e) and (best == null or e.from.len > best.?.from.len)) best = e;
        }
        if (best) |e| {
            try out.appendSlice(a, text[copied..i]);
            try out.appendSlice(a, e.to);
            i += e.from.len;
            copied = i;
            changed = true;
        } else {
            i += 1;
        }
    }
    if (!changed) return text;
    try out.appendSlice(a, text[copied..]);
    return out.items;
}

// ---------------------------------------------------------------- tests

const t = std.testing;

fn expectApply(text: []const u8, entries: []const Entry, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings(want, try apply(arena.allocator(), text, entries));
}

test "whole words only, case-insensitive by default" {
    const d = [_]Entry{.{ .from = "kubectl", .to = "cube control" }};
    try expectApply("Run kubectl or Kubectl, not kubectld.", &d, "Run cube control or cube control, not kubectld.");
}

test "case-sensitive entries" {
    const d = [_]Entry{.{ .from = "SQL", .to = "sequel", .case_sensitive = true }};
    try expectApply("SQL and sql", &d, "sequel and sql");
}

test "symbols in entries and the longest match wins" {
    const d = [_]Entry{
        .{ .from = "C", .to = "see" },
        .{ .from = "C++", .to = "C plus plus" },
    };
    try expectApply("I wrote C++ and C.", &d, "I wrote C plus plus and see.");
}

test "no entries or no match returns the input" {
    try expectApply("unchanged", &.{}, "unchanged");
    const d = [_]Entry{.{ .from = "zz", .to = "x" }};
    try expectApply("unchanged", &d, "unchanged");
}
