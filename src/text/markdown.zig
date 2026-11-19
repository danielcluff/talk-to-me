//! Markdown → speakable text blocks, using md4c.
//!
//! Each block (heading, paragraph, list item, announcement) becomes one string
//! that ends with sentence punctuation, so the chunker and the voice both get a
//! natural pause between blocks. Code blocks are skipped and announced, links
//! read as their text, bare URLs as their domain, tables as a row count.

const std = @import("std");
const c = @import("c");
const unicode = std.unicode;

pub const CodeBlocks = enum { announce, skip, read };
pub const Tables = enum { announce, skip, read };

pub const Options = struct {
    code_blocks: CodeBlocks = .announce,
    tables: Tables = .announce,
    images: bool = false, // read image alt text
};

pub const Blocks = struct {
    arena: std.heap.ArenaAllocator,
    items: []const []const u8,

    pub fn deinit(self: *Blocks) void {
        self.arena.deinit();
    }
};

const State = struct {
    arena: std.mem.Allocator,
    opts: Options,
    blocks: std.ArrayList([]const u8) = .empty,
    cur: std.ArrayList(u8) = .empty,
    /// > 0 while inside content that must not be spoken
    mute: u32 = 0,
    in_code_block: bool = false,
    in_table: u32 = 0,
    /// >0 inside an autolink; its text is replaced by the domain
    in_autolink: u32 = 0,
    oom: bool = false,

    fn flush(s: *State) void {
        const trimmed = std.mem.trim(u8, s.cur.items, " \t\r\n");
        if (trimmed.len == 0) {
            s.cur.clearRetainingCapacity();
            return;
        }
        var text = std.ArrayList(u8).initCapacity(s.arena, trimmed.len + 1) catch return s.fail();
        // collapse runs of whitespace
        var prev_space = false;
        for (trimmed) |ch| {
            const space = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
            if (space) {
                if (!prev_space) text.appendAssumeCapacity(' ');
            } else {
                text.appendAssumeCapacity(ch);
            }
            prev_space = space;
        }
        if (!endsWithTerminal(text.items)) {
            text.append(s.arena, '.') catch return s.fail();
        }
        s.blocks.append(s.arena, text.items) catch return s.fail();
        s.cur.clearRetainingCapacity();
    }

    fn emitBlock(s: *State, text: []const u8) void {
        s.flush();
        s.blocks.append(s.arena, text) catch return s.fail();
    }

    fn append(s: *State, text: []const u8) void {
        if (s.mute > 0 or s.in_autolink > 0) return;
        appendSpeakable(s.arena, &s.cur, text) catch s.fail();
    }

    fn fail(s: *State) void {
        s.oom = true;
    }
};

fn endsWithTerminal(text: []const u8) bool {
    var i = text.len;
    while (i > 0) : (i -= 1) {
        const ch = text[i - 1];
        if (ch == ')' or ch == '"' or ch == '\'' or ch == ']' or ch == '*' or ch == '_') continue;
        return ch == '.' or ch == '!' or ch == '?' or ch == ':' or ch == ';';
    }
    return false;
}

/// Append text, dropping emoji, pictographs, box drawing and similar symbols
/// that the voice would either skip or mispronounce.
pub fn appendSpeakable(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var view = unicode.Utf8View.init(text) catch {
        try out.appendSlice(gpa, text);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = unicode.utf8Decode(slice) catch continue;
        if (isSilentSymbol(cp)) continue;
        if (cp == 0x2192) { // → reads naturally as "to"
            try out.appendSlice(gpa, " to ");
            continue;
        }
        try out.appendSlice(gpa, slice);
    }
}

fn isSilentSymbol(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or // emoji, pictographs
        (cp >= 0x2600 and cp <= 0x27BF) or // misc symbols, dingbats (✅ ✔ ★)
        (cp >= 0x2500 and cp <= 0x259F) or // box drawing, blocks
        (cp >= 0x2B00 and cp <= 0x2BFF) or // misc symbols and arrows
        cp == 0xFE0F or cp == 0xFE0E or cp == 0x200D; // variation selectors, ZWJ
}

/// Domain of a URL for speaking: "https://www.github.com/x" → "github.com".
pub fn urlDomain(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    if (std.mem.startsWith(u8, rest, "mailto:")) rest = rest["mailto:".len..];
    if (std.mem.indexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];
    if (std.mem.startsWith(u8, rest, "www.")) rest = rest[4..];
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    return rest[0..end];
}

fn decodeEntity(e: []const u8) []const u8 {
    const map = .{
        .{ "&amp;", "&" },  .{ "&lt;", "<" },    .{ "&gt;", ">" },  .{ "&quot;", "\"" },
        .{ "&#39;", "'" },  .{ "&apos;", "'" },  .{ "&nbsp;", " " }, .{ "&mdash;", " — " },
        .{ "&ndash;", "–" }, .{ "&hellip;", "…" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, e, pair[0])) return pair[1];
    }
    return "";
}

fn enterBlock(t: c.MD_BLOCKTYPE, detail: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const s: *State = @ptrCast(@alignCast(user.?));
    switch (t) {
        c.MD_BLOCK_H, c.MD_BLOCK_P, c.MD_BLOCK_LI, c.MD_BLOCK_QUOTE => s.flush(),
        c.MD_BLOCK_CODE => {
            s.flush();
            s.in_code_block = true;
            if (s.opts.code_blocks != .read) s.mute += 1;
        },
        c.MD_BLOCK_HTML => s.mute += 1,
        c.MD_BLOCK_TABLE => {
            s.flush();
            s.in_table += 1;
            if (s.opts.tables != .read) {
                s.mute += 1;
                if (s.opts.tables == .announce) {
                    const d: *const c.MD_BLOCK_TABLE_DETAIL = @ptrCast(@alignCast(detail.?));
                    const n = d.body_row_count;
                    const msg = if (n == 1)
                        std.fmt.allocPrint(s.arena, "Table with 1 row.", .{})
                    else
                        std.fmt.allocPrint(s.arena, "Table with {d} rows.", .{n});
                    s.emitBlock(msg catch return 0);
                }
            }
        },
        c.MD_BLOCK_TR => if (s.opts.tables == .read) s.flush(),
        c.MD_BLOCK_TH, c.MD_BLOCK_TD => if (s.opts.tables == .read) s.append(", "),
        else => {},
    }
    return 0;
}

fn leaveBlock(t: c.MD_BLOCKTYPE, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const s: *State = @ptrCast(@alignCast(user.?));
    switch (t) {
        c.MD_BLOCK_H, c.MD_BLOCK_P, c.MD_BLOCK_LI, c.MD_BLOCK_QUOTE => s.flush(),
        c.MD_BLOCK_CODE => {
            s.in_code_block = false;
            if (s.opts.code_blocks != .read) {
                s.mute -= 1;
                if (s.opts.code_blocks == .announce) s.emitBlock("Code block.");
            } else s.flush();
        },
        c.MD_BLOCK_HTML => s.mute -= 1,
        c.MD_BLOCK_TABLE => {
            s.in_table -= 1;
            if (s.opts.tables != .read) s.mute -= 1 else s.flush();
        },
        c.MD_BLOCK_TR => if (s.opts.tables == .read) s.flush(),
        else => {},
    }
    return 0;
}

fn enterSpan(t: c.MD_SPANTYPE, detail: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const s: *State = @ptrCast(@alignCast(user.?));
    switch (t) {
        c.MD_SPAN_A => {
            const d: *const c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
            if (d.is_autolink != 0) {
                const href = d.href.text[0..d.href.size];
                s.append(urlDomain(href));
                s.in_autolink += 1;
            }
        },
        c.MD_SPAN_IMG => if (!s.opts.images) {
            s.mute += 1;
        },
        c.MD_SPAN_LATEXMATH, c.MD_SPAN_LATEXMATH_DISPLAY => s.mute += 1,
        else => {},
    }
    return 0;
}

fn leaveSpan(t: c.MD_SPANTYPE, detail: ?*anyopaque, user: ?*anyopaque) callconv(.c) c_int {
    const s: *State = @ptrCast(@alignCast(user.?));
    switch (t) {
        c.MD_SPAN_A => {
            const d: *const c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
            if (d.is_autolink != 0) s.in_autolink -= 1;
        },
        c.MD_SPAN_IMG => if (!s.opts.images) {
            s.mute -= 1;
        },
        c.MD_SPAN_LATEXMATH, c.MD_SPAN_LATEXMATH_DISPLAY => s.mute -= 1,
        else => {},
    }
    return 0;
}

fn onText(t: c.MD_TEXTTYPE, text: [*c]const c.MD_CHAR, size: c.MD_SIZE, user: ?*anyopaque) callconv(.c) c_int {
    const s: *State = @ptrCast(@alignCast(user.?));
    const slice: []const u8 = text[0..size];
    switch (t) {
        c.MD_TEXT_NORMAL, c.MD_TEXT_CODE => s.append(slice),
        c.MD_TEXT_SOFTBR, c.MD_TEXT_BR => s.append(if (s.in_code_block) "\n" else " "),
        c.MD_TEXT_ENTITY => s.append(decodeEntity(slice)),
        else => {},
    }
    return 0;
}

pub fn toBlocks(gpa: std.mem.Allocator, markdown: []const u8, opts: Options) !Blocks {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var state: State = .{ .arena = arena.allocator(), .opts = opts };

    var parser = std.mem.zeroes(c.MD_PARSER);
    parser.abi_version = 0;
    parser.flags = c.MD_FLAG_TABLES | c.MD_FLAG_STRIKETHROUGH | c.MD_FLAG_TASKLISTS |
        c.MD_FLAG_PERMISSIVEURLAUTOLINKS | c.MD_FLAG_PERMISSIVEWWWAUTOLINKS |
        c.MD_FLAG_LATEXMATHSPANS | c.MD_FLAG_NOHTMLSPANS;
    parser.enter_block = enterBlock;
    parser.leave_block = leaveBlock;
    parser.enter_span = enterSpan;
    parser.leave_span = leaveSpan;
    parser.text = onText;

    if (c.md_parse(markdown.ptr, @intCast(markdown.len), &parser, &state) != 0) return error.MarkdownParse;
    state.flush();
    if (state.oom) return error.OutOfMemory;
    return .{ .arena = arena, .items = state.blocks.items };
}

/// Plain text: blank lines separate blocks; whitespace inside a block collapses.
pub fn plainToBlocks(gpa: std.mem.Allocator, text: []const u8) !Blocks {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var state: State = .{ .arena = arena.allocator(), .opts = .{} };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            state.flush();
        } else {
            state.append(line);
            state.append(" ");
        }
    }
    state.flush();
    if (state.oom) return error.OutOfMemory;
    return .{ .arena = arena, .items = state.blocks.items };
}

// ---------------------------------------------------------------- tests

fn expectBlocks(md: []const u8, opts: Options, want: []const []const u8) !void {
    var got = try toBlocks(std.testing.allocator, md, opts);
    defer got.deinit();
    if (got.items.len != want.len) {
        std.debug.print("got {d} blocks:\n", .{got.items.len});
        for (got.items) |b| std.debug.print("  [{s}]\n", .{b});
    }
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "headings, paragraphs and lists become punctuated blocks" {
    try expectBlocks(
        \\# Summary
        \\
        \\I fixed the **parser** and the
        \\chunker.
        \\
        \\- first item
        \\- second item!
    , .{}, &.{ "Summary.", "I fixed the parser and the chunker.", "first item.", "second item!" });
}

test "code blocks are announced, inline code is read" {
    try expectBlocks(
        \\Run `zig build` now:
        \\
        \\```sh
        \\zig build --release
        \\```
        \\
        \\Done.
    , .{}, &.{ "Run zig build now:", "Code block.", "Done." });
    try expectBlocks("Before.\n\n```\nx = 1\n```\n", .{ .code_blocks = .skip }, &.{"Before."});
}

test "links read their text, bare URLs their domain" {
    try expectBlocks("See [the docs](https://example.com/a/b) or https://www.github.com/x/y for more.", .{}, &.{"See the docs or github.com for more."});
}

test "tables are announced with their row count" {
    try expectBlocks(
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\| 3 | 4 |
    , .{}, &.{"Table with 2 rows."});
}

test "emoji and box drawing are dropped, arrows read as to" {
    try expectBlocks("✅ Tests pass 🎉 and A → B", .{}, &.{"Tests pass and A to B."});
}

test "plain text splits on blank lines" {
    var got = try plainToBlocks(std.testing.allocator, "one line\nwraps here\n\nsecond   para");
    defer got.deinit();
    try std.testing.expectEqual(@as(usize, 2), got.items.len);
    try std.testing.expectEqualStrings("one line wraps here.", got.items[0]);
    try std.testing.expectEqualStrings("second para.", got.items[1]);
}
