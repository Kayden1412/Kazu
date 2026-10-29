//! Report formatting: table, JSON, Markdown, HTML and ZON.

const std = @import("std");
const languages = @import("languages.zig");
const json = std.json;

pub const Format = enum {
    table,
    json,
    md,
    html,
    zon,

    pub fn parse(value: []const u8) ?Format {
        if (std.ascii.eqlIgnoreCase(value, "table") or std.ascii.eqlIgnoreCase(value, "text")) return .table;
        if (std.ascii.eqlIgnoreCase(value, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(value, "md") or std.ascii.eqlIgnoreCase(value, "markdown")) return .md;
        if (std.ascii.eqlIgnoreCase(value, "html") or std.ascii.eqlIgnoreCase(value, "htm")) return .html;
        if (std.ascii.eqlIgnoreCase(value, "zon")) return .zon;
        return null;
    }
};

pub const SortField = enum {
    files,
    lines,
    blank,
    comments,
    code,
    name,

    pub fn parse(value: []const u8) ?SortField {
        if (std.ascii.eqlIgnoreCase(value, "files") or std.ascii.eqlIgnoreCase(value, "file")) return .files;
        if (std.ascii.eqlIgnoreCase(value, "lines") or std.ascii.eqlIgnoreCase(value, "line")) return .lines;
        if (std.ascii.eqlIgnoreCase(value, "blank") or std.ascii.eqlIgnoreCase(value, "blanks")) return .blank;
        if (std.ascii.eqlIgnoreCase(value, "comment") or std.ascii.eqlIgnoreCase(value, "comments")) return .comments;
        if (std.ascii.eqlIgnoreCase(value, "code")) return .code;
        if (std.ascii.eqlIgnoreCase(value, "name") or std.ascii.eqlIgnoreCase(value, "language")) return .name;
        return null;
    }
};

pub const Summary = struct {
    lang: u16,
    files: u64 = 0,
    lines: u64 = 0,
    blank: u64 = 0,
    comment: u64 = 0,
    code: u64 = 0,

    pub fn name(self: Summary) []const u8 {
        return languages.languages[self.lang].name;
    }
};

pub const Totals = struct {
    files: u64 = 0,
    lines: u64 = 0,
    blank: u64 = 0,
    comment: u64 = 0,
    code: u64 = 0,
};

pub fn total(rows: []const Summary) Totals {
    var result: Totals = .{};
    for (rows) |row| {
        result.files += row.files;
        result.lines += row.lines;
        result.blank += row.blank;
        result.comment += row.comment;
        result.code += row.code;
    }
    return result;
}

pub fn sortRows(rows: []Summary, field: SortField) void {
    std.mem.sort(Summary, rows, field, lessThan);
}

fn lessThan(field: SortField, a: Summary, b: Summary) bool {
    switch (field) {
        .name => return std.mem.order(u8, a.name(), b.name()) == .lt,
        .files => if (a.files != b.files) return a.files > b.files,
        .lines => if (a.lines != b.lines) return a.lines > b.lines,
        .blank => if (a.blank != b.blank) return a.blank > b.blank,
        .comments => if (a.comment != b.comment) return a.comment > b.comment,
        .code => if (a.code != b.code) return a.code > b.code,
    }
    // Numeric sorts are descending, with the name as a stable tie-breaker.
    return std.mem.order(u8, a.name(), b.name()) == .lt;
}

pub fn writeReport(
    writer: *std.Io.Writer,
    format: Format,
    rows: []const Summary,
    totals: Totals,
) !void {
    switch (format) {
        .table => try writeTable(writer, rows, totals),
        .json => try writeJson(writer, rows),
        .md => try writeMarkdown(writer, rows, totals),
        .html => try writeHtml(writer, rows, totals),
        .zon => try writeZon(writer, rows),
    }
}

const Widths = struct {
    language: usize,
    files: usize,
    lines: usize,
    blank: usize,
    comment: usize,
    code: usize,

    fn total(self: Widths) usize {
        // Two spaces between each of the six columns.
        return self.language + self.files + self.lines + self.blank + self.comment + self.code + 10;
    }
};

fn digitCount(value: u64) usize {
    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    return text.len;
}

fn widthsFor(rows: []const Summary, totals: Totals) Widths {
    var widths: Widths = .{
        .language = "Language".len,
        .files = @max("Files".len, digitCount(totals.files)),
        .lines = @max("Lines".len, digitCount(totals.lines)),
        .blank = @max("Blank".len, digitCount(totals.blank)),
        .comment = @max("Comment".len, digitCount(totals.comment)),
        .code = @max("Code".len, digitCount(totals.code)),
    };
    for (rows) |row| {
        widths.language = @max(widths.language, row.name().len);
    }
    return widths;
}

fn writeLeft(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) try writer.splatByteAll(' ', width - text.len);
}

fn writeRight(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    if (text.len < width) try writer.splatByteAll(' ', width - text.len);
    try writer.writeAll(text);
}

fn writeNumber(writer: *std.Io.Writer, value: u64, width: usize) !void {
    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try writeRight(writer, text, width);
}

fn writeSeparator(writer: *std.Io.Writer, width: usize) !void {
    var i: usize = 0;
    while (i < width) : (i += 1) try writer.writeAll("\u{2500}");
    try writer.writeByte('\n');
}

fn writeTableRow(
    writer: *std.Io.Writer,
    name: []const u8,
    files: u64,
    lines: u64,
    blank: u64,
    comment: u64,
    code: u64,
    widths: Widths,
) !void {
    try writeLeft(writer, name, widths.language);
    try writer.writeAll("  ");
    try writeNumber(writer, files, widths.files);
    try writer.writeAll("  ");
    try writeNumber(writer, lines, widths.lines);
    try writer.writeAll("  ");
    try writeNumber(writer, blank, widths.blank);
    try writer.writeAll("  ");
    try writeNumber(writer, comment, widths.comment);
    try writer.writeAll("  ");
    try writeNumber(writer, code, widths.code);
    try writer.writeByte('\n');
}

fn writeTable(writer: *std.Io.Writer, rows: []const Summary, totals: Totals) !void {
    const widths = widthsFor(rows, totals);
    const width = widths.total();

    try writeSeparator(writer, width);
    try writeLeft(writer, "Language", widths.language);
    try writer.writeAll("  ");
    try writeRight(writer, "Files", widths.files);
    try writer.writeAll("  ");
    try writeRight(writer, "Lines", widths.lines);
    try writer.writeAll("  ");
    try writeRight(writer, "Blank", widths.blank);
    try writer.writeAll("  ");
    try writeRight(writer, "Comment", widths.comment);
    try writer.writeAll("  ");
    try writeRight(writer, "Code", widths.code);
    try writer.writeByte('\n');
    try writeSeparator(writer, width);

    for (rows) |row| {
        try writeTableRow(writer, row.name(), row.files, row.lines, row.blank, row.comment, row.code, widths);
    }

    try writeSeparator(writer, width);
    try writeTableRow(writer, "Total", totals.files, totals.lines, totals.blank, totals.comment, totals.code, widths);
    try writeSeparator(writer, width);
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try json.Stringify.encodeJsonString(text, .{}, writer);
}

fn writeJson(writer: *std.Io.Writer, rows: []const Summary) !void {
    try writer.writeAll("[\n");
    for (rows, 0..) |row, i| {
        try writer.writeAll("  {\n    \"Name\": ");
        try writeJsonString(writer, row.name());
        try writer.writeAll(",\n    \"Files\": ");
        try writer.print("{d}", .{row.files});
        try writer.writeAll(",\n    \"Lines\": ");
        try writer.print("{d}", .{row.lines});
        try writer.writeAll(",\n    \"Blank\": ");
        try writer.print("{d}", .{row.blank});
        try writer.writeAll(",\n    \"Comment\": ");
        try writer.print("{d}", .{row.comment});
        try writer.writeAll(",\n    \"Code\": ");
        try writer.print("{d}", .{row.code});
        try writer.writeAll("\n  }");
        if (i + 1 < rows.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("]\n");
}

fn writeMarkdownEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        if (byte == '|' or byte == '\\') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
}

fn writeMarkdown(writer: *std.Io.Writer, rows: []const Summary, totals: Totals) !void {
    try writer.writeAll("| Language | Files | Lines | Blank | Comment | Code |\n");
    try writer.writeAll("| :--- | ---: | ---: | ---: | ---: | ---: |\n");
    for (rows) |row| {
        try writer.writeAll("| ");
        try writeMarkdownEscaped(writer, row.name());
        try writer.print(" | {d} | {d} | {d} | {d} | {d} |\n", .{
            row.files, row.lines, row.blank, row.comment, row.code,
        });
    }
    try writer.print("| **Total** | **{d}** | **{d}** | **{d}** | **{d}** | **{d}** |\n", .{
        totals.files, totals.lines, totals.blank, totals.comment, totals.code,
    });
}

fn writeHtmlEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn writeHtml(writer: *std.Io.Writer, rows: []const Summary, totals: Totals) !void {
    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>kazu - code statistics</title>
        \\<style>
        \\body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; margin: 2rem; color: #1f2328; }
        \\h1 { font-size: 1.4rem; }
        \\table { border-collapse: collapse; font-variant-numeric: tabular-nums; }
        \\th, td { padding: 0.35rem 1rem; border-bottom: 1px solid #d0d7de; }
        \\th { text-align: left; background: #f6f8fa; }
        \\th.num, td.num { text-align: right; }
        \\tbody tr:hover { background: #f6f8fa; }
        \\tfoot td { font-weight: 600; border-top: 2px solid #1f2328; }
        \\</style>
        \\</head>
        \\<body>
        \\<h1>kazu report</h1>
        \\<table>
        \\  <thead>
        \\    <tr><th>Language</th><th class="num">Files</th><th class="num">Lines</th><th class="num">Blank</th><th class="num">Comment</th><th class="num">Code</th></tr>
        \\  </thead>
        \\  <tbody>
        \\
    );

    for (rows) |row| {
        try writer.writeAll("    <tr><td>");
        try writeHtmlEscaped(writer, row.name());
        try writer.print("</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td></tr>\n", .{
            row.files, row.lines, row.blank, row.comment, row.code,
        });
    }

    try writer.writeAll("  </tbody>\n  <tfoot>\n    <tr><td>Total</td>");
    try writer.print("<td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td>", .{
        totals.files, totals.lines, totals.blank, totals.comment, totals.code,
    });
    try writer.writeAll("</tr>\n  </tfoot>\n</table>\n</body>\n</html>\n");
}

fn writeZon(writer: *std.Io.Writer, rows: []const Summary) !void {
    if (rows.len == 0) {
        try writer.writeAll(".{}\n");
        return;
    }

    try writer.writeAll(".{\n");
    for (rows) |row| {
        try writer.writeAll("    .{\n        .name = \"");
        try writer.print("{f}", .{std.zig.fmtString(row.name())});
        try writer.writeAll("\",\n        .files = ");
        try writer.print("{d}", .{row.files});
        try writer.writeAll(",\n        .lines = ");
        try writer.print("{d}", .{row.lines});
        try writer.writeAll(",\n        .blank = ");
        try writer.print("{d}", .{row.blank});
        try writer.writeAll(",\n        .comment = ");
        try writer.print("{d}", .{row.comment});
        try writer.writeAll(",\n        .code = ");
        try writer.print("{d}", .{row.code});
        try writer.writeAll(",\n    },\n");
    }
    try writer.writeAll("}\n");
}

test "json output is valid JSON" {
    const gpa = std.testing.allocator;

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();

    var rows = [_]Summary{
        .{ .lang = languages.byExtension("zig").?, .files = 2, .lines = 10, .blank = 2, .comment = 3, .code = 5 },
    };
    try writeReport(&allocating.writer, .json, &rows, total(&rows));

    const Parsed = struct {
        Name: []const u8,
        Files: u64,
        Lines: u64,
        Blank: u64,
        Comment: u64,
        Code: u64,
    };
    const parsed = try std.json.parseFromSlice([]Parsed, gpa, allocating.writer.buffer[0..allocating.writer.end], .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("Zig", parsed.value[0].Name);
    try std.testing.expectEqual(@as(u64, 5), parsed.value[0].Code);
}

test "zon output is valid ZON" {
    const gpa = std.testing.allocator;

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();

    var rows = [_]Summary{
        .{ .lang = languages.byExtension("zig").?, .files = 2, .lines = 10, .blank = 2, .comment = 3, .code = 5 },
        .{ .lang = languages.byExtension("py").?, .files = 1, .lines = 4, .blank = 1, .comment = 1, .code = 2 },
    };
    try writeReport(&allocating.writer, .zon, &rows, total(&rows));

    const source = try gpa.dupeSentinel(u8, allocating.writer.buffer[0..allocating.writer.end], 0);
    defer gpa.free(source);

    const Parsed = struct {
        name: []const u8,
        files: u64,
        lines: u64,
        blank: u64,
        comment: u64,
        code: u64,
    };

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = try std.zon.parse.fromSlice([]Parsed, .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    });

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("Zig", parsed[0].name);
    try std.testing.expectEqual(@as(u64, 5), parsed[0].code);
    try std.testing.expectEqualStrings("Python", parsed[1].name);
}
