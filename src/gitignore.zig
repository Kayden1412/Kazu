//! `.gitignore` parsing and matching.
//!
//! This implements the parts of gitignore syntax that matter while walking a
//! source tree: comments, negation, anchored patterns, directory-only
//! patterns, `*`, `?`, character classes and `**`.
//!
//! Patterns are evaluated in order and the last matching pattern wins.  A
//! nested `.gitignore` is appended after its parent, so rules in deeper files
//! override rules from shallower ones.

const std = @import("std");

pub const Pattern = struct {
    /// Pattern text without the leading `!`, leading `/` or trailing `/`.
    /// Backslash escapes are preserved for the glob matcher.
    text: []const u8,
    negated: bool = false,
    dir_only: bool = false,
    anchored: bool = false,
};

pub const File = struct {
    /// Directory containing this `.gitignore`, relative to the scan root.
    /// Empty for the root itself. Uses `/` separators.
    base: []const u8,
    patterns: []const Pattern,
    contents: []u8,
};

pub const Set = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Set) void {
        while (self.files.items.len > 0) self.pop();
        self.files.deinit(self.allocator);
    }

    /// Add a `.gitignore` file by copying its contents.
    pub fn add(self: *Set, base: []const u8, contents: []const u8) !void {
        const owned = try self.allocator.dupe(u8, contents);
        try self.addOwned(base, owned);
    }

    /// Add a `.gitignore` file, taking ownership of `contents`.
    ///
    /// `contents` must have been allocated with `self.allocator`.  On error it
    /// is freed before returning.
    pub fn addOwned(self: *Set, base: []const u8, contents: []u8) !void {
        errdefer self.allocator.free(contents);

        const owned_base = try self.allocator.dupe(u8, base);
        errdefer self.allocator.free(owned_base);

        var patterns: std.ArrayList(Pattern) = .empty;
        errdefer patterns.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (parsePattern(line)) |pattern| {
                try patterns.append(self.allocator, pattern);
            }
        }

        const owned_patterns = try patterns.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_patterns);

        try self.files.append(self.allocator, .{
            .base = owned_base,
            .patterns = owned_patterns,
            .contents = contents,
        });
    }

    /// Remove the most recently added `.gitignore`.
    pub fn pop(self: *Set) void {
        if (self.files.items.len == 0) return;

        const index = self.files.items.len - 1;
        const file = self.files.items[index];
        self.files.items.len = index;

        self.allocator.free(file.patterns);
        self.allocator.free(file.base);
        self.allocator.free(file.contents);
    }

    /// Return true when `rel_path` is ignored.
    ///
    /// `rel_path` is relative to the scan root and uses `/` separators.
    pub fn isIgnored(self: *const Set, rel_path: []const u8, is_dir: bool) bool {
        var ignored = false;

        for (self.files.items) |file| {
            var sub_path = rel_path;
            if (file.base.len > 0) {
                if (!std.mem.startsWith(u8, rel_path, file.base)) continue;
                if (rel_path.len == file.base.len) continue;
                if (rel_path[file.base.len] != '/') continue;
                sub_path = rel_path[file.base.len + 1 ..];
            }

            const name = baseName(sub_path);
            for (file.patterns) |pattern| {
                if (pattern.dir_only and !is_dir) continue;

                const matched = if (pattern.anchored)
                    globMatch(pattern.text, sub_path)
                else
                    globMatch(pattern.text, name);

                if (matched) ignored = !pattern.negated;
            }
        }

        return ignored;
    }
};

fn parsePattern(line_in: []const u8) ?Pattern {
    var line = line_in;
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }

    line = trimTrailingSpaces(line);
    if (line.len == 0) return null;
    if (line[0] == '#') return null;

    var negated = false;
    if (line[0] == '!') {
        negated = true;
        line = line[1..];
    } else if (line.len >= 2 and line[0] == '\\' and (line[1] == '#' or line[1] == '!')) {
        // `\#` and `\!` are literal characters, not comment/negation markers.
        line = line[1..];
    }

    if (line.len == 0) return null;

    var dir_only = false;
    if (line[line.len - 1] == '/') {
        dir_only = true;
        while (line.len > 0 and line[line.len - 1] == '/') {
            line = line[0 .. line.len - 1];
        }
    }
    if (line.len == 0) return null;

    var anchored = false;
    if (line[0] == '/') {
        anchored = true;
        line = line[1..];
    }
    if (line.len == 0) return null;

    if (std.mem.indexOfScalar(u8, line, '/') != null) anchored = true;

    return .{
        .text = line,
        .negated = negated,
        .dir_only = dir_only,
        .anchored = anchored,
    };
}

/// Trim unescaped trailing spaces.  A space preceded by an odd number of
/// backslashes is escaped and therefore part of the pattern.
fn trimTrailingSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') {
        var backslashes: usize = 0;
        var i = end - 1;
        while (i > 0 and line[i - 1] == '\\') {
            backslashes += 1;
            i -= 1;
        }
        if (backslashes % 2 == 1) break;
        end -= 1;
    }
    return line[0..end];
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| {
        return path[index + 1 ..];
    }
    return path;
}

const ClassMatch = struct {
    matched: bool,
    next: usize,
};

/// Match a single character against a `[...]` class starting at `start`.
/// Returns null when there is no closing `]`, in which case `[` is literal.
fn matchClass(pattern: []const u8, start: usize, ch: u8) ?ClassMatch {
    var i = start + 1;
    if (i >= pattern.len) return null;

    var negated = false;
    if (pattern[i] == '!' or pattern[i] == '^') {
        negated = true;
        i += 1;
    }

    var matched = false;
    var first = true;

    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) {
            return .{
                .matched = if (negated) !matched else matched,
                .next = i + 1,
            };
        }

        var low = pattern[i];
        if (low == '\\' and i + 1 < pattern.len) {
            i += 1;
            low = pattern[i];
        }

        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            var high = pattern[i + 2];
            var advance: usize = 3;
            if (high == '\\' and i + 3 < pattern.len) {
                high = pattern[i + 3];
                advance = 4;
            }
            if (ch >= low and ch <= high) matched = true;
            i += advance;
        } else {
            if (ch == low) matched = true;
            i += 1;
        }

        first = false;
    }

    return null;
}

/// Match a gitignore glob against a path.
///
/// `*` and `?` never cross `/`.  `**` is special only when it is a complete
/// path component (`**/`, `/**/`, or a trailing `/**`); otherwise it behaves
/// like a regular `*`, matching git's rules.
fn globMatch(pattern: []const u8, path: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;

    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                var q = p + 1;
                while (q < pattern.len and pattern[q] == '*') q += 1;

                const is_double = q > p + 1;
                const at_component_start = p == 0 or pattern[p - 1] == '/';
                const at_component_end = q == pattern.len or pattern[q] == '/';
                const special = is_double and at_component_start and at_component_end;

                if (special and q == pattern.len) {
                    // Trailing `/**` (or a bare `**`) matches everything left.
                    return true;
                }

                if (special) {
                    // `**/` matches zero or more complete path components.
                    if (globMatch(pattern[q + 1 ..], path[s..])) return true;

                    var i = s;
                    while (i < path.len) {
                        if (path[i] == '/') {
                            if (globMatch(pattern[q + 1 ..], path[i + 1 ..])) return true;
                        }
                        i += 1;
                    }
                    return false;
                }

                // Regular `*`: any run of characters except `/`.
                if (globMatch(pattern[q..], path[s..])) return true;

                var i = s;
                while (i < path.len and path[i] != '/') {
                    if (globMatch(pattern[q..], path[i + 1 ..])) return true;
                    i += 1;
                }
                return false;
            },
            '?' => {
                if (s >= path.len or path[s] == '/') return false;
                p += 1;
                s += 1;
            },
            '[' => {
                if (s >= path.len or path[s] == '/') return false;
                const class = matchClass(pattern, p, path[s]) orelse {
                    if (path[s] != '[') return false;
                    p += 1;
                    s += 1;
                    continue;
                };
                if (!class.matched) return false;
                p = class.next;
                s += 1;
            },
            '\\' => {
                if (p + 1 < pattern.len) {
                    if (s >= path.len or path[s] != pattern[p + 1]) return false;
                    p += 2;
                    s += 1;
                } else {
                    if (s >= path.len or path[s] != '\\') return false;
                    p += 1;
                    s += 1;
                }
            },
            else => {
                if (s >= path.len or path[s] != pattern[p]) return false;
                p += 1;
                s += 1;
            },
        }
    }

    return s == path.len;
}

test "basic patterns and negation" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "*.log\nbuild/\n!keep.log\n");

    try std.testing.expect(set.isIgnored("a.log", false));
    try std.testing.expect(set.isIgnored("sub/a.log", false));
    try std.testing.expect(set.isIgnored("build", true));
    try std.testing.expect(!set.isIgnored("build", false));
    try std.testing.expect(!set.isIgnored("keep.log", false));
}

test "anchored patterns only match from their directory" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "/root.txt\ndoc/*.md\nfoo/bar\n");

    try std.testing.expect(set.isIgnored("root.txt", false));
    try std.testing.expect(!set.isIgnored("sub/root.txt", false));
    try std.testing.expect(set.isIgnored("doc/a.md", false));
    try std.testing.expect(!set.isIgnored("sub/doc/a.md", false));
    try std.testing.expect(set.isIgnored("foo/bar", false));
    try std.testing.expect(!set.isIgnored("sub/foo/bar", false));
}

test "double star patterns" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "**/foo\na/**/b\na/**\n");

    try std.testing.expect(set.isIgnored("foo", false));
    try std.testing.expect(set.isIgnored("x/foo", false));
    try std.testing.expect(set.isIgnored("x/y/foo", false));
    try std.testing.expect(!set.isIgnored("foo/bar", false));

    try std.testing.expect(set.isIgnored("a/b", false));
    try std.testing.expect(set.isIgnored("a/x/b", false));
    try std.testing.expect(set.isIgnored("a/x/y/b", false));

    try std.testing.expect(set.isIgnored("a/x", false));
    try std.testing.expect(set.isIgnored("a/x/y", false));
    try std.testing.expect(!set.isIgnored("a", false));

    // `a/**b` is not a complete `**` component, so it behaves like `a/*b`.
    var partial = Set.init(std.testing.allocator);
    defer partial.deinit();
    try partial.add("", "a/**b\n");
    try std.testing.expect(partial.isIgnored("a/xb", false));
    try std.testing.expect(!partial.isIgnored("a/x/yb", false));
}

test "nested gitignore overrides parent rules" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "*.log\n");
    try set.add("sub", "!important.log\n");

    try std.testing.expect(set.isIgnored("a.log", false));
    try std.testing.expect(set.isIgnored("sub/other.log", false));
    try std.testing.expect(!set.isIgnored("sub/important.log", false));
}

test "escaped markers and trailing spaces" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "\\#file\n\\!file\nfoo\\ \nbar   \n");

    try std.testing.expect(set.isIgnored("#file", false));
    try std.testing.expect(set.isIgnored("!file", false));
    try std.testing.expect(set.isIgnored("foo ", false));
    try std.testing.expect(set.isIgnored("bar", false));
    try std.testing.expect(!set.isIgnored("bar   ", false));
}

test "character classes and question mark" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "file[0-9].txt\n[!a]bc\nx?z\n");

    try std.testing.expect(set.isIgnored("file1.txt", false));
    try std.testing.expect(set.isIgnored("file9.txt", false));
    try std.testing.expect(!set.isIgnored("filex.txt", false));

    try std.testing.expect(set.isIgnored("xbc", false));
    try std.testing.expect(!set.isIgnored("abc", false));

    try std.testing.expect(set.isIgnored("xyz", false));
    try std.testing.expect(!set.isIgnored("xz", false));
}

test "comments, blank lines and crlf" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "# comment\r\n\r\n*.tmp\r\n");

    try std.testing.expect(set.isIgnored("a.tmp", false));
    try std.testing.expect(!set.isIgnored("# comment", false));
}

test "last matching pattern wins" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "*.log\n!keep.log\n*.log\n");

    try std.testing.expect(set.isIgnored("keep.log", false));
}

test "directory-only patterns can be re-included" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();

    try set.add("", "build/\n!build/\n");

    try std.testing.expect(!set.isIgnored("build", true));
}
