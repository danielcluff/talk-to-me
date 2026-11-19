//! Split speakable blocks into synthesis chunks.
//!
//! A chunk is the unit of synthesis, prefetch and sentence navigation
//! (next/previous). Kokoro's cost scales with audio length and has no
//! per-call overhead worth amortizing (Phase 0), so chunks are single
//! sentences, and sentences longer than `clause_len` split at clause
//! boundaries (, ; : dash) where the voice pauses anyway.
//!
//! Chunk length bounds interrupt latency: synthesis can't be preempted
//! (Metal submits a graph as two command buffers and never checks an abort
//! hook before both are queued), so a new job waits for the chunk in flight,
//! about 23 ms per character on an M4. `max_len` is the hard cap; past it a
//! sentence splits at a space.
//!
//! The first chunk of a job is kept short (first clause) because time to
//! first audio is proportional to its length.

const std = @import("std");

pub const Options = struct {
    /// Split sentences longer than this at clause boundaries.
    clause_len: usize = 100,
    /// Hard cap; longer pieces without a clause boundary split at a space.
    max_len: usize = 150,
    /// Split the job's first sentence at a clause boundary when it is longer
    /// than this; 0 disables.
    first_max: usize = 60,
    /// Silence after a chunk that ends a block (paragraph, heading, item).
    block_pause_ms: u32 = 250,
};

pub const Chunk = struct {
    text: []const u8,
    pause_after_ms: u32 = 0,
};

const abbreviations = [_][]const u8{
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e",
    "approx", "no", "fig", "inc", "ltd", "co", "cf", "al",
};

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// True when the '.' at `dot` ends an abbreviation or an initial ("J. Smith").
fn isAbbreviation(text: []const u8, dot: usize) bool {
    var start = dot;
    while (start > 0 and !isSpace(text[start - 1]) and text[start - 1] != '(') start -= 1;
    const word = text[start..dot];
    if (word.len == 1 and std.ascii.isUpper(word[0])) return true; // initial
    var buf: [16]u8 = undefined;
    if (word.len == 0 or word.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, word);
    for (abbreviations) |a| {
        if (std.mem.eql(u8, lower, a)) return true;
    }
    return false;
}

/// Ends of sentences in `text`: index one past the terminal punctuation
/// (including closing quotes/brackets).
fn nextSentenceEnd(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        const is_ellipsis = ch == 0xE2 and i + 2 < text.len and text[i + 1] == 0x80 and text[i + 2] == 0xA6; // …
        if (ch != '.' and ch != '!' and ch != '?' and !is_ellipsis) continue;
        var end = if (is_ellipsis) i + 3 else i + 1;
        while (end < text.len and (text[end] == '.' or text[end] == '!' or text[end] == '?')) end += 1;
        while (end < text.len and (text[end] == '"' or text[end] == '\'' or text[end] == ')' or text[end] == ']')) end += 1;
        if (end < text.len and !isSpace(text[end])) {
            i = end - 1;
            continue; // "3.5", "file.zig", "e.g.x"
        }
        if (ch == '.' and end == i + 1 and isAbbreviation(text, i)) continue;
        return end;
    }
    return text.len;
}

/// Last clause boundary (after , ; : or a dash) in text[lo..hi], or null.
fn clauseBreak(text: []const u8, lo: usize, hi: usize) ?usize {
    var i = @min(hi, text.len);
    while (i > lo) : (i -= 1) {
        const ch = text[i - 1];
        if ((ch == ',' or ch == ';' or ch == ':') and i < text.len and isSpace(text[i])) return i;
        // em dash / en dash (UTF-8 E2 80 94 / E2 80 93) followed by a space
        if (i >= 3 and text[i - 3] == 0xE2 and text[i - 2] == 0x80 and (ch == 0x94 or ch == 0x93) and i < text.len and isSpace(text[i])) return i;
    }
    return null;
}

/// First clause boundary in text[lo..hi], or null.
fn firstClauseBreak(text: []const u8, lo: usize, hi: usize) ?usize {
    var i = lo;
    while (i < @min(hi, text.len)) : (i += 1) {
        if (clauseBreak(text, i, i + 1)) |b| return b;
    }
    return null;
}

fn lastSpace(text: []const u8, lo: usize, hi: usize) ?usize {
    var i = @min(hi, text.len);
    while (i > lo) : (i -= 1) {
        if (isSpace(text[i - 1])) return i;
    }
    return null;
}

fn push(gpa: std.mem.Allocator, out: *std.ArrayList(Chunk), text: []const u8) !void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len > 0) try out.append(gpa, .{ .text = t });
}

fn pushSentence(gpa: std.mem.Allocator, out: *std.ArrayList(Chunk), sentence: []const u8, opts: Options) !void {
    var rest = std.mem.trim(u8, sentence, " \t\r\n");
    // short first chunk: first clause of the job's first sentence
    if (out.items.len == 0 and opts.first_max > 0 and rest.len > opts.first_max) {
        if (clauseBreak(rest, 12, opts.first_max + 30)) |cut| {
            try push(gpa, out, rest[0..cut]);
            rest = std.mem.trim(u8, rest[cut..], " \t\r\n");
        }
    }
    const min_piece = 20;
    while (rest.len > opts.clause_len) {
        // last clause before clause_len, else the first one before max_len
        const cut = clauseBreak(rest, min_piece, opts.clause_len) orelse
            firstClauseBreak(rest, opts.clause_len, opts.max_len) orelse
            (if (rest.len > opts.max_len)
                lastSpace(rest, opts.max_len / 3, opts.max_len) orelse opts.max_len
            else
                break);
        if (rest.len - cut < min_piece / 2) break; // don't leave a tiny tail
        try push(gpa, out, rest[0..cut]);
        rest = std.mem.trim(u8, rest[cut..], " \t\r\n");
    }
    try push(gpa, out, rest);
}

/// Chunk the blocks of one job. Chunk texts are slices of `blocks`.
pub fn chunk(gpa: std.mem.Allocator, blocks: []const []const u8, opts: Options) ![]Chunk {
    var out: std.ArrayList(Chunk) = .empty;
    errdefer out.deinit(gpa);
    for (blocks) |block| {
        var pos: usize = 0;
        while (pos < block.len) {
            const end = nextSentenceEnd(block, pos);
            try pushSentence(gpa, &out, block[pos..end], opts);
            pos = end;
        }
        if (out.items.len > 0) out.items[out.items.len - 1].pause_after_ms = opts.block_pause_ms;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- tests

fn expectChunks(blocks: []const []const u8, opts: Options, want: []const []const u8) !void {
    const got = try chunk(std.testing.allocator, blocks, opts);
    defer std.testing.allocator.free(got);
    if (got.len != want.len) {
        std.debug.print("got {d} chunks:\n", .{got.len});
        for (got) |ch| std.debug.print("  [{s}]\n", .{ch.text});
    }
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g.text);
}

test "splits sentences, keeps abbreviations, decimals and file names" {
    try expectChunks(&.{"Dr. Smith edited main.zig at 3.5 MHz. It works! Does it? Yes."}, .{ .first_max = 0 }, &.{
        "Dr. Smith edited main.zig at 3.5 MHz.", "It works!", "Does it?", "Yes.",
    });
}

test "initials and e.g. do not end sentences" {
    try expectChunks(&.{"J. R. R. Tolkien wrote it, e.g. the Hobbit. Next."}, .{ .first_max = 0 }, &.{
        "J. R. R. Tolkien wrote it, e.g. the Hobbit.", "Next.",
    });
}

test "first chunk is split at the first clause" {
    try expectChunks(&.{"I updated the parser, so headings and lists are read naturally now. Done."}, .{}, &.{
        "I updated the parser,", "so headings and lists are read naturally now.", "Done.",
    });
}

test "long sentences split at clauses, then spaces" {
    const long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega";
    const got = try chunk(std.testing.allocator, &.{long}, .{ .clause_len = 40, .max_len = 50, .first_max = 0 });
    defer std.testing.allocator.free(got);
    try std.testing.expect(got.len >= 3);
    for (got) |ch| try std.testing.expect(ch.text.len <= 50);
}

test "sentences over clause_len split at clauses, short ones stay whole" {
    const s1 = "When several agents finish at the same time, their replies wait in a single queue, so you always hear one voice at a time, and you can pause or stop any of them.";
    const got = try chunk(std.testing.allocator, &.{ s1, "A short sentence, with a comma." }, .{ .first_max = 0 });
    defer std.testing.allocator.free(got);
    for (got) |ch| try std.testing.expect(ch.text.len <= 150);
    try std.testing.expect(got.len >= 3);
    for (got[0 .. got.len - 2]) |ch| try std.testing.expect(ch.text[ch.text.len - 1] == ',');
    try std.testing.expectEqualStrings("A short sentence, with a comma.", got[got.len - 1].text);
}

test "a long sentence without clauses splits at a space under max_len" {
    const s1 = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu";
    const got = try chunk(std.testing.allocator, &.{s1}, .{ .first_max = 0 });
    defer std.testing.allocator.free(got);
    try std.testing.expect(got.len == 2);
    for (got) |ch| try std.testing.expect(ch.text.len <= 150);
}

test "block ends carry a pause" {
    const got = try chunk(std.testing.allocator, &.{ "One. Two.", "Three." }, .{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(@as(u32, 0), got[0].pause_after_ms);
    try std.testing.expectEqual(@as(u32, 250), got[1].pause_after_ms);
    try std.testing.expectEqual(@as(u32, 250), got[2].pause_after_ms);
}
