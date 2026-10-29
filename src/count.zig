//! Line classification and counting.
//!
//! A line is `blank` when it contains only whitespace, `comment` when it
//! contains only comment text, and `code` otherwise.  A line that mixes code
//! and a comment is counted as code, matching the behaviour of scc and cloc.
//!
//! `Counter` scans bytes incrementally, so callers can stream a file through a
//! fixed-size buffer without allocating memory proportional to the file.

const std = @import("std");
const languages = @import("languages.zig");

pub const Counts = struct {
    lines: u64 = 0,
    blank: u64 = 0,
    comment: u64 = 0,
    code: u64 = 0,
};

pub const LineKind = enum { blank, comment, code };

/// Count the lines in an in-memory file.
pub fn countLines(content: []const u8, lang: *const languages.Language) Counts {
    var counter = Counter.init(lang);
    counter.feed(content);
    return counter.finish();
}

/// Longest comment marker in the language table.  Chunk boundaries can split a
/// marker, so the streaming counter keeps at most this many bytes for the next
/// `feed` call.
const max_marker_len = blk: {
    var longest: usize = 1;
    for (languages.languages) |lang| {
        for (lang.line_comments) |marker| longest = @max(longest, marker.len);
        for (lang.block_comments) |block| {
            longest = @max(longest, block.start.len);
            longest = @max(longest, block.end.len);
        }
    }
    break :blk longest;
};

comptime {
    std.debug.assert(max_marker_len <= 32);
}

/// Incremental line counter.
///
/// `feed` accepts arbitrary chunks of a file and does not allocate: markers
/// split across a chunk boundary are carried in a fixed-size buffer until the
/// next chunk arrives.  `finish` flushes the carry and returns the totals.
///
/// The scanner is a byte-level state machine rather than a line splitter, so
/// memory use is independent of file size and line length.
pub const Counter = struct {
    lang: *const languages.Language,
    counts: Counts = .{},
    /// Longest marker used by `lang`; bounds the carry buffer.
    max_marker: usize,

    // State that spans lines.
    in_block: bool = false,
    block_end: []const u8 = "",

    // State that resets at every newline.
    in_line_comment: bool = false,
    in_string: bool = false,
    quote: u8 = 0,
    escaped: bool = false,
    line_started: bool = false,
    all_ws: bool = true,
    has_code: bool = false,
    forced_code: bool = false,
    prefix_pending: bool = false,
    prefix_active: bool = false,
    prefix_mask: u32 = 0,
    prefix_len: usize = 0,

    pending: [max_marker_len]u8 = undefined,
    pending_len: usize = 0,

    /// Bytes that can change state in plain code: a newline, a quote, or the
    /// first byte of a comment marker or line prefix.  Everything else is an
    /// ordinary code byte and can be skipped in bulk.
    special: [256]bool,

    pub fn init(lang: *const languages.Language) Counter {
        std.debug.assert(lang.line_prefixes.len <= 32);

        var special: [256]bool = @splat(false);
        special['\n'] = true;
        for (lang.quotes) |quote| special[quote] = true;
        for (lang.line_comments) |marker| {
            if (marker.len > 0) special[marker[0]] = true;
        }
        for (lang.block_comments) |block| {
            if (block.start.len > 0) special[block.start[0]] = true;
        }
        for (lang.line_prefixes) |prefix| {
            if (prefix.len > 0) special[prefix[0]] = true;
        }

        return .{
            .lang = lang,
            .max_marker = maxMarker(lang),
            .prefix_pending = lang.line_prefixes.len > 0,
            .special = special,
        };
    }

    /// Consume the next chunk of the file.  Bytes that may start a marker
    /// spanning the chunk boundary are held back until the next call.
    pub fn feed(self: *Counter, chunk: []const u8) void {
        if (chunk.len == 0) return;

        if (self.pending_len == 0) {
            self.feedRest(chunk);
            return;
        }

        const carried = self.pending_len;
        const take = @min(chunk.len, self.max_marker);
        var combined: [2 * max_marker_len]u8 = undefined;
        const total = carried + take;
        @memcpy(combined[0..carried], self.pending[0..carried]);
        @memcpy(combined[carried..total], chunk[0..take]);

        const used = self.scan(combined[0..total], false);
        if (used == total) {
            self.pending_len = 0;
            if (take < chunk.len) self.feedRest(chunk[take..]);
            return;
        }

        if (take == chunk.len) {
            // The chunk ended inside a possible marker; carry the tail.
            self.setPending(combined[used..total]);
            return;
        }

        // There was enough lookahead to resolve the carried bytes, so the
        // deferral starts inside `chunk`.  Re-scan from there with the rest
        // of the chunk available.
        std.debug.assert(used >= carried);
        self.pending_len = 0;
        self.feedRest(chunk[used - carried ..]);
    }

    fn feedRest(self: *Counter, data: []const u8) void {
        const used = self.scan(data, false);
        self.setPending(data[used..]);
    }

    /// Flush any carried bytes and the final unterminated line.
    pub fn finish(self: *Counter) Counts {
        if (self.pending_len > 0) {
            _ = self.scan(self.pending[0..self.pending_len], true);
            self.pending_len = 0;
        }
        if (self.line_started) self.finalizeLine();
        return self.counts;
    }

    fn setPending(self: *Counter, suffix: []const u8) void {
        std.debug.assert(suffix.len < max_marker_len);
        @memcpy(self.pending[0..suffix.len], suffix);
        self.pending_len = suffix.len;
    }

    fn note(self: *Counter, byte: u8) void {
        self.line_started = true;
        if (!isSpace(byte)) self.all_ws = false;
    }

    fn finalizeLine(self: *Counter) void {
        self.counts.lines += 1;
        if (self.all_ws) {
            self.counts.blank += 1;
        } else if (self.has_code) {
            self.counts.code += 1;
        } else {
            self.counts.comment += 1;
        }

        self.line_started = false;
        self.all_ws = true;
        self.has_code = false;
        self.forced_code = false;
        self.in_line_comment = false;
        self.in_string = false;
        self.quote = 0;
        self.escaped = false;
        self.prefix_pending = self.lang.line_prefixes.len > 0;
        self.prefix_active = false;
        self.prefix_mask = 0;
        self.prefix_len = 0;
    }

    /// Scan `data`, returning how many bytes were consumed.  When `final` is
    /// false the tail may be held back if it is a prefix of a comment marker.
    fn scan(self: *Counter, data: []const u8, final: bool) usize {
        const block_comments = self.lang.block_comments;
        const line_comments = self.lang.line_comments;
        const line_prefixes = self.lang.line_prefixes;
        const quotes = self.lang.quotes;

        var i: usize = 0;
        while (i < data.len) {
            const byte = data[i];

            if (byte == '\n') {
                self.finalizeLine();
                i += 1;
                continue;
            }

            // The rest of a line comment or forced-code line is uniform: jump
            // straight to the newline.  Entering either state already updated
            // `all_ws` (or `has_code`) for the line.
            if (self.forced_code or self.in_line_comment) {
                i = std.mem.findScalarPos(u8, data, i, '\n') orelse data.len;
                continue;
            }

            if (self.in_string) {
                if (self.escaped) {
                    self.note(data[i]);
                    self.escaped = false;
                    i += 1;
                    continue;
                }

                // String content is always code and never blank, so only the
                // closing quote, an escape, or a newline needs attention.
                var stop = i;
                while (stop < data.len) : (stop += 1) {
                    const b = data[stop];
                    if (b == self.quote or b == '\\' or b == '\n') break;
                }
                i = stop;
                if (i >= data.len) return i;
                const string_byte = data[i];
                if (string_byte == '\n') continue;
                self.note(string_byte);
                if (string_byte == '\\') {
                    self.escaped = true;
                } else {
                    self.in_string = false;
                }
                i += 1;
                continue;
            }

            // Line prefixes take precedence over comment markers, matching the
            // old line-based classifier.
            if (self.prefix_pending) {
                if (byte == ' ' or byte == '\t') {
                    self.note(byte);
                    i += 1;
                    continue;
                }
                self.prefix_pending = false;
                self.prefix_active = line_prefixes.len > 0;
                self.prefix_len = 0;
                self.prefix_mask = if (line_prefixes.len == 32)
                    std.math.maxInt(u32)
                else
                    (@as(u32, 1) << @as(u5, @intCast(line_prefixes.len))) - 1;
            }

            if (self.prefix_active) {
                var mask = self.prefix_mask;
                var matched = false;
                for (line_prefixes, 0..) |prefix, index| {
                    const bit = @as(u32, 1) << @as(u5, @intCast(index));
                    if (mask & bit == 0) continue;
                    if (self.prefix_len >= prefix.len or byte != prefix[self.prefix_len]) {
                        mask &= ~bit;
                    } else if (self.prefix_len + 1 == prefix.len) {
                        matched = true;
                    }
                }
                self.prefix_mask = mask;
                self.prefix_len += 1;
                if (matched) {
                    self.forced_code = true;
                    self.has_code = true;
                    self.note(byte);
                    i += 1;
                    continue;
                }
                if (mask == 0) self.prefix_active = false;
            }

            if (self.in_block) {
                const end_marker = self.block_end;
                if (end_marker.len == 0) {
                    self.in_block = false;
                    continue;
                }

                // Block text is comment text.  Skip to the end marker or the
                // next newline, whichever comes first, tracking whether this
                // line has any non-space content.
                var stop = i;
                var saw_non_space = false;
                const track_ws = self.all_ws;
                while (stop < data.len) : (stop += 1) {
                    const b = data[stop];
                    if (b == '\n' or b == end_marker[0]) break;
                    if (track_ws and !saw_non_space and !isSpace(b)) saw_non_space = true;
                }
                if (saw_non_space) self.all_ws = false;
                if (stop > i) self.line_started = true;
                i = stop;
                if (i >= data.len) return i;

                const block_byte = data[i];
                if (block_byte == '\n') continue;
                switch (matchMarker(data, i, end_marker, final)) {
                    .matched => {
                        self.note(block_byte);
                        i += end_marker.len;
                        self.in_block = false;
                        continue;
                    },
                    .need_more => return i,
                    .no_match => {
                        self.note(block_byte);
                        i += 1;
                        continue;
                    },
                }
            }

            // Ordinary code: skip a run of bytes that cannot start a marker
            // or a string.  This is the common case for source text.
            if (!self.special[byte] and !self.prefix_active and !self.prefix_pending) {
                var stop = i + 1;
                while (stop < data.len and !self.special[data[stop]]) stop += 1;
                if (!self.has_code) {
                    for (data[i..stop]) |b| {
                        if (!isSpace(b)) {
                            self.has_code = true;
                            self.all_ws = false;
                            break;
                        }
                    }
                }
                self.line_started = true;
                i = stop;
                continue;
            }

            // Block comments must be tested before line comments: several
            // languages share a prefix (Lua `--[[` vs `--`, Julia `#=` vs `#`).
            var entered = false;
            for (block_comments) |block| {
                switch (matchMarker(data, i, block.start, final)) {
                    .matched => {
                        self.in_block = true;
                        self.block_end = block.end;
                        self.note(byte);
                        i += block.start.len;
                        entered = true;
                        break;
                    },
                    .need_more => return i,
                    .no_match => {},
                }
            }
            if (entered) continue;

            for (line_comments) |marker| {
                switch (matchMarker(data, i, marker, final)) {
                    .matched => {
                        self.in_line_comment = true;
                        self.note(byte);
                        i += marker.len;
                        entered = true;
                        break;
                    },
                    .need_more => return i,
                    .no_match => {},
                }
            }
            if (entered) continue;

            if (isQuote(quotes, byte)) {
                self.in_string = true;
                self.quote = byte;
                self.escaped = false;
                self.has_code = true;
                self.note(byte);
                i += 1;
                continue;
            }

            if (!isSpace(byte)) self.has_code = true;
            self.note(byte);
            i += 1;
        }
        return i;
    }
};

const Match = enum { matched, no_match, need_more };

fn matchMarker(data: []const u8, index: usize, marker: []const u8, final: bool) Match {
    if (marker.len == 0) return .no_match;
    const rest = data[index..];
    if (rest.len >= marker.len) {
        // Reject on the first byte before building the comparison; most
        // candidate bytes fail here.
        if (rest[0] != marker[0]) return .no_match;
        return if (std.mem.eql(u8, rest[0..marker.len], marker)) .matched else .no_match;
    }
    if (!final and std.mem.startsWith(u8, marker, rest)) return .need_more;
    return .no_match;
}

fn maxMarker(lang: *const languages.Language) usize {
    var longest: usize = 1;
    for (lang.line_comments) |marker| longest = @max(longest, marker.len);
    for (lang.block_comments) |block| {
        longest = @max(longest, block.start.len);
        longest = @max(longest, block.end.len);
    }
    return longest;
}

fn isSpace(byte: u8) bool {
    // Printable bytes above the space are never whitespace; this keeps the
    // common case to a single compare.
    if (byte > ' ') return false;
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

fn isQuote(quotes: []const u8, byte: u8) bool {
    for (quotes) |quote| {
        if (quote == byte) return true;
    }
    return false;
}

const testing = std.testing;

fn language(name: []const u8) *const languages.Language {
    for (languages.languages, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate.name, name)) return &languages.languages[i];
    }
    unreachable;
}

test "plain code and blank lines" {
    const counts = countLines("a\n\nb\n", language("Zig"));
    try testing.expectEqual(@as(u64, 3), counts.lines);
    try testing.expectEqual(@as(u64, 2), counts.code);
    try testing.expectEqual(@as(u64, 1), counts.blank);
    try testing.expectEqual(@as(u64, 0), counts.comment);
}

test "line comments" {
    const counts = countLines("// one\ncode // two\n// three\n", language("Zig"));
    try testing.expectEqual(@as(u64, 3), counts.lines);
    try testing.expectEqual(@as(u64, 1), counts.code);
    try testing.expectEqual(@as(u64, 2), counts.comment);
}

test "block comments span lines" {
    const counts = countLines("/* one\n two\n*/\ncode\n", language("C"));
    try testing.expectEqual(@as(u64, 4), counts.lines);
    try testing.expectEqual(@as(u64, 3), counts.comment);
    try testing.expectEqual(@as(u64, 1), counts.code);
}

test "mixed comment and code is code" {
    const counts = countLines("/* c */ int x = 1;\nint y = 2; // c\n", language("C"));
    try testing.expectEqual(@as(u64, 2), counts.lines);
    try testing.expectEqual(@as(u64, 2), counts.code);
    try testing.expectEqual(@as(u64, 0), counts.comment);
}

test "comment markers inside strings are ignored" {
    const counts = countLines("const url = \"http://example.com\";\n", language("Zig"));
    try testing.expectEqual(@as(u64, 1), counts.code);
    try testing.expectEqual(@as(u64, 0), counts.comment);

    const template = countLines("const url = `http://example.com`;\n", language("JavaScript"));
    try testing.expectEqual(@as(u64, 1), template.code);
    try testing.expectEqual(@as(u64, 0), template.comment);
}

test "block comment prefix beats line comment prefix" {
    const counts = countLines("--[[ one\ntwo\n]]\n", language("Lua"));
    try testing.expectEqual(@as(u64, 3), counts.lines);
    try testing.expectEqual(@as(u64, 3), counts.comment);
}

test "empty file and single newline" {
    const empty = countLines("", language("Zig"));
    try testing.expectEqual(@as(u64, 0), empty.lines);

    const newline = countLines("\n", language("Zig"));
    try testing.expectEqual(@as(u64, 1), newline.lines);
    try testing.expectEqual(@as(u64, 1), newline.blank);
}

test "crlf line endings" {
    const counts = countLines("// c\r\ncode\r\n", language("Zig"));
    try testing.expectEqual(@as(u64, 2), counts.lines);
    try testing.expectEqual(@as(u64, 1), counts.comment);
    try testing.expectEqual(@as(u64, 1), counts.code);
}

test "zig multiline string lines are code" {
    const counts = countLines("const s =\n    \\\\ /* not a comment\n;\n", language("Zig"));
    try testing.expectEqual(@as(u64, 3), counts.lines);
    try testing.expectEqual(@as(u64, 3), counts.code);
    try testing.expectEqual(@as(u64, 0), counts.comment);
}

test "html comments" {
    const counts = countLines("<!-- one\n two -->\n<p>hi</p>\n", language("HTML"));
    try testing.expectEqual(@as(u64, 2), counts.comment);
    try testing.expectEqual(@as(u64, 1), counts.code);
}

test "comments in languages added from scc" {
    const abap = countLines("WRITE 'hi'.\n\" comment\n\n", language("ABAP"));
    try testing.expectEqual(@as(u64, 1), abap.code);
    try testing.expectEqual(@as(u64, 1), abap.comment);
    try testing.expectEqual(@as(u64, 1), abap.blank);

    const forth = countLines(": sq dup * ;\n\\ comment\n( block\ncomment )\n", language("Forth"));
    try testing.expectEqual(@as(u64, 1), forth.code);
    try testing.expectEqual(@as(u64, 3), forth.comment);

    const smalltalk = countLines("x := 1.\n\" a comment \"\ny := 2.\n", language("Smalltalk"));
    try testing.expectEqual(@as(u64, 2), smalltalk.code);
    try testing.expectEqual(@as(u64, 1), smalltalk.comment);

    const plain = countLines("hello\n# not a comment\n", language("Plain Text"));
    try testing.expectEqual(@as(u64, 2), plain.code);
    try testing.expectEqual(@as(u64, 0), plain.comment);
}

fn expectCounts(expected: Counts, actual: Counts) !void {
    try testing.expectEqual(expected.lines, actual.lines);
    try testing.expectEqual(expected.blank, actual.blank);
    try testing.expectEqual(expected.comment, actual.comment);
    try testing.expectEqual(expected.code, actual.code);
}

test "chunk boundaries do not change counts" {
    const snippets = [_][]const u8{
        "/* one\ntwo\n*/\ncode\n",
        "--[[ one\ntwo\n]]\n",
        "<!-- one\n two -->\n<p>hi</p>\n",
        "{% comment %} x {% endcomment %}\ncode\n",
        "const s =\n    \\\\ /* not a comment\n;\n",
        "\"comment\"\ncode\n",
        "// c\r\ncode\r\n",
        "a\r\n\r\nb",
    };
    const names = [_][]const u8{ "C", "Lua", "HTML", "Liquid", "Zig", "ABAP", "Zig", "Python" };

    for (snippets, names) |text, name| {
        const lang = language(name);
        const expected = countLines(text, lang);
        var size: usize = 1;
        while (size <= max_marker_len + 2) : (size += 1) {
            var counter = Counter.init(lang);
            var i: usize = 0;
            while (i < text.len) : (i += size) {
                counter.feed(text[i..@min(i + size, text.len)]);
            }
            try expectCounts(expected, counter.finish());
        }
    }
}

test "markers split across every chunk size" {
    const cases = [_]struct { lang: []const u8, text: []const u8 }{
        .{ .lang = "C", .text = "/* a */ b\n" },
        .{ .lang = "Lua", .text = "--[[ a ]] b\n" },
        .{ .lang = "HTML", .text = "<!-- a --> b\n" },
        .{ .lang = "Liquid", .text = "{% comment %} a {% endcomment %} b\n" },
        .{ .lang = "Nim", .text = "#[ a ]# b\n" },
        .{ .lang = "Julia", .text = "#= a =# b\n" },
        .{ .lang = "Smalltalk", .text = "\" a \" b\n" },
    };

    for (cases) |case| {
        const lang = language(case.lang);
        const expected = countLines(case.text, lang);
        var split: usize = 0;
        while (split <= case.text.len) : (split += 1) {
            var counter = Counter.init(lang);
            counter.feed(case.text[0..split]);
            counter.feed(case.text[split..]);
            try expectCounts(expected, counter.finish());
        }
    }
}

test "streaming matches whole-buffer counting on random input" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const alphabet = "ab /*-<!#{}()'\"\\\n\t\r";
    var buffer: [192]u8 = undefined;

    for (&languages.languages) |*lang| {
        for (0..3) |_| {
            const len = random.intRangeAtMost(usize, 0, buffer.len);
            for (buffer[0..len]) |*byte| {
                byte.* = alphabet[random.intRangeAtMost(usize, 0, alphabet.len - 1)];
            }

            const expected = countLines(buffer[0..len], lang);
            var size: usize = 1;
            while (size <= 5) : (size += 1) {
                var counter = Counter.init(lang);
                var i: usize = 0;
                while (i < len) : (i += size) {
                    counter.feed(buffer[i..@min(i + size, len)]);
                }
                try expectCounts(expected, counter.finish());
            }
        }
    }
}
