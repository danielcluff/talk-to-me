//! Cutting text without splitting a character: a cut in the middle of a
//! multi-byte UTF-8 sequence makes the JSON writer emit an array of numbers
//! instead of a string, which clients then fail to decode.

const std = @import("std");

/// The longest prefix of `s` that is at most `max` bytes and ends on a
/// character boundary.
pub fn prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    // back up over continuation bytes (10xxxxxx) to the start of a character
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Copy a prefix of `src` into `dst` as a NUL-terminated string.
pub fn copyZ(dst: []u8, src: []const u8) void {
    const p = prefix(src, dst.len - 1);
    @memcpy(dst[0..p.len], p);
    dst[p.len] = 0;
}

test "prefix never splits a character" {
    const t = std.testing;
    try t.expectEqualStrings("abc", prefix("abc", 10));
    try t.expectEqualStrings("ab", prefix("abc", 2));
    // "’" is 3 bytes (E2 80 99)
    try t.expectEqualStrings("it", prefix("it’s", 3));
    try t.expectEqualStrings("it", prefix("it’s", 4));
    try t.expectEqualStrings("it’", prefix("it’s", 5));
    // a 4-byte emoji
    try t.expectEqualStrings("a", prefix("a😀", 4));
    try t.expect(std.unicode.utf8ValidateSlice(prefix("— — —", 7)));
}

test "copyZ terminates and stays valid" {
    var buf: [5]u8 = undefined;
    copyZ(&buf, "ab😀cd");
    try std.testing.expectEqualStrings("ab", std.mem.sliceTo(&buf, 0));
}
