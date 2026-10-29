//! kazu - fast parallel source code counter.
//!
//! Directory walking is sequential and uses `std.Io.Dir.walkSelectively`, so
//! excluded and gitignored directories can be pruned before they are opened.
//! File paths are collected in batches, and each batch is split across a group
//! of `std.Io` workers with one atomic counter. Every file and directory
//! operation goes through `std.Io`; its threaded backend runs the syscall
//! inline in the calling thread.

const std = @import("std");
const kazu = @import("kazu");

const languages = kazu.languages;
const count = kazu.count;
const format = kazu.format;
const gitignore = kazu.gitignore;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const version = "0.1.0";
const max_file_size: u64 = 256 * 1024 * 1024;
const max_gitignore_size: usize = 1024 * 1024;
/// Files are counted in chunks so a worker never allocates a buffer the size
/// of the file.  One buffer is allocated per worker and reused for every file.
const read_buffer_size: usize = 64 * 1024;

const default_excluded_dirs = [_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "zig-cache",
    ".zig-cache",
    "zig-out",
    "__pycache__",
    ".venv",
    "venv",
    "target",
};

const help_text =
    \\kazu - fast parallel source code counter
    \\
    \\Usage:
    \\  kazu [options] [path...]
    \\
    \\Options:
    \\  -f, --format <fmt>        Output format: table (default), json, md, html, zon
    \\  -s, --sort <field>        Sort rows by: files, lines, blank, comments, code, name
    \\  -w, --workers <n>         Number of counting workers (default: CPU count)
    \\      --exclude-dir <name>  Skip a directory name (repeatable)
    \\      --include-ext <ext>   Only count these extensions (repeatable)
    \\      --exclude-ext <ext>   Skip these extensions (repeatable)
    \\      --no-gitignore        Do not read .gitignore files
    \\  -h, --help                Show this help
    \\  -v, --version             Show the version
    \\
    \\With no paths, the current directory is scanned. Language is detected from
    \\the file name, extension, or a #! interpreter line. Lines are classified as
    \\code, comment, or blank; mixed code/comment lines count as code.
    \\
    \\.gitignore files are honored by default; use --no-gitignore to disable.
    \\
    \\Examples:
    \\  kazu
    \\  kazu src tests
    \\  kazu --format json --sort code .
    \\  kazu --format md --sort files --exclude-dir vendor .
    \\
;

const Config = struct {
    format: format.Format = .table,
    sort: format.SortField = .code,
    workers: usize,
    paths: []const []const u8 = &.{"."},
    exclude_dirs: []const []const u8 = &.{},
    include_exts: []const []const u8 = &.{},
    exclude_exts: []const []const u8 = &.{},
    gitignore: bool = true,
};

const Action = union(enum) {
    run: Config,
    help,
    version,
};

const FileTask = struct {
    path: []const u8,
    lang: ?u16,
};

const FileResult = struct {
    lang: u16,
    counts: count.Counts,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const action = parseArgs(arena, args) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(2),
        else => return err,
    };

    switch (action) {
        .help => try writeStdout(init.io, help_text),
        .version => try writeStdout(init.io, "kazu " ++ version ++ "\n"),
        .run => |config| try run(init, config),
    }
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn invalid(comptime message: []const u8, args: anytype) error{InvalidArgs} {
    std.debug.print("kazu: " ++ message ++ "\n", args);
    std.debug.print("Try 'kazu --help' for more information.\n", .{});
    return error.InvalidArgs;
}

const Option = struct {
    name: []const u8,
    value: ?[]const u8,
};

fn splitOption(arg: []const u8) Option {
    if (std.mem.indexOfScalar(u8, arg, '=')) |index| {
        return .{ .name = arg[0..index], .value = arg[index + 1 ..] };
    }
    return .{ .name = arg, .value = null };
}

fn optionValue(
    option: Option,
    args: []const []const u8,
    index: *usize,
) ?[]const u8 {
    if (option.value) |value| return value;
    if (index.* + 1 >= args.len) return null;
    index.* += 1;
    return args[index.*];
}

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Action {
    var format_value: format.Format = .table;
    var sort_value: format.SortField = .code;
    var workers: ?usize = null;
    var use_gitignore = true;
    var show_help = false;
    var show_version = false;

    var paths: std.ArrayList([]const u8) = .empty;
    var exclude_dirs: std.ArrayList([]const u8) = .empty;
    var include_exts: std.ArrayList([]const u8) = .empty;
    var exclude_exts: std.ArrayList([]const u8) = .empty;

    try exclude_dirs.appendSlice(arena, &default_excluded_dirs);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            try paths.appendSlice(arena, args[i + 1 ..]);
            break;
        }
        if (arg.len == 0 or arg[0] != '-') {
            try paths.append(arena, arg);
            continue;
        }

        const option = splitOption(arg);
        if (std.mem.eql(u8, option.name, "-h") or std.mem.eql(u8, option.name, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, option.name, "-v") or std.mem.eql(u8, option.name, "--version")) {
            show_version = true;
        } else if (std.mem.eql(u8, option.name, "-f") or std.mem.eql(u8, option.name, "--format")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("option '{s}' requires a value", .{option.name});
            format_value = format.Format.parse(value) orelse
                return invalid("invalid format '{s}' (expected table, json, md, html or zon)", .{value});
        } else if (std.mem.eql(u8, option.name, "-s") or std.mem.eql(u8, option.name, "--sort")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("option '{s}' requires a value", .{option.name});
            sort_value = format.SortField.parse(value) orelse
                return invalid("invalid sort field '{s}' (expected files, lines, blank, comments, code or name)", .{value});
        } else if (std.mem.eql(u8, option.name, "-w") or std.mem.eql(u8, option.name, "--workers")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("option '{s}' requires a value", .{option.name});
            const parsed = std.fmt.parseInt(usize, value, 10) catch
                return invalid("invalid worker count '{s}'", .{value});
            if (parsed == 0 or parsed > 128)
                return invalid("worker count must be between 1 and 128", .{});
            workers = parsed;
        } else if (std.mem.eql(u8, option.name, "--exclude-dir")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("option '{s}' requires a value", .{option.name});
            try exclude_dirs.append(arena, value);
        } else if (std.mem.eql(u8, option.name, "--include-ext")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("option '{s}' requires a value", .{option.name});
            try include_exts.append(arena, value);
        } else if (std.mem.eql(u8, option.name, "--exclude-ext")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("option '{s}' requires a value", .{option.name});
            try exclude_exts.append(arena, value);
        } else if (std.mem.eql(u8, option.name, "--no-gitignore")) {
            use_gitignore = false;
        } else {
            return invalid("unknown option '{s}'", .{arg});
        }
    }

    if (show_help) return .help;
    if (show_version) return .version;

    const config = Config{
        .format = format_value,
        .sort = sort_value,
        .workers = workers orelse defaultWorkers(),
        .paths = if (paths.items.len > 0) paths.items else &.{"."},
        .exclude_dirs = exclude_dirs.items,
        .include_exts = include_exts.items,
        .exclude_exts = exclude_exts.items,
        .gitignore = use_gitignore,
    };
    return .{ .run = config };
}

fn defaultWorkers() usize {
    const cpus = std.Thread.getCpuCount() catch 4;
    return @min(@max(cpus, 1), 16);
}

const batch_size: usize = 4096;

/// Walks the tree and hands batches of files to a short-lived worker group.
/// Keeping the queue out of the hot path avoids per-file channel wakeups: each
/// batch is split dynamically with one atomic counter.
const Batcher = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    workers: usize,
    stats: []format.Summary,
    tasks: std.ArrayList(FileTask) = .empty,
    results: std.ArrayList(?FileResult) = .empty,

    /// Takes ownership of `task.path` even when an error is returned.
    fn push(self: *Batcher, task: FileTask) !void {
        self.tasks.append(self.gpa, task) catch |err| {
            self.gpa.free(task.path);
            return err;
        };
        if (self.tasks.items.len == batch_size) try self.flush();
    }

    fn flush(self: *Batcher) !void {
        if (self.tasks.items.len == 0) return;

        try self.results.resize(self.gpa, self.tasks.items.len);
        @memset(self.results.items, null);

        var next = std.atomic.Value(usize).init(0);
        var group: std.Io.Group = .init;
        var spawned: usize = 0;
        const wanted = @min(self.workers, self.tasks.items.len);
        while (spawned < wanted) : (spawned += 1) {
            // A failed spawn is fine as long as at least one worker runs: the
            // shared counter keeps every worker busy until the batch is empty.
            group.concurrent(self.io, batchWorker, .{
                self.io,
                self.gpa,
                self.tasks.items,
                self.results.items,
                &next,
            }) catch break;
        }
        if (spawned == 0) {
            // No concurrency available (for example a single-threaded `Io`
            // implementation); count the batch on this thread.
            batchWorker(self.io, self.gpa, self.tasks.items, self.results.items, &next) catch {};
        } else {
            try group.await(self.io);
        }

        for (self.tasks.items, self.results.items) |task, maybe_result| {
            self.gpa.free(task.path);
            const result = maybe_result orelse continue;
            const stat = &self.stats[result.lang];
            stat.files += 1;
            stat.lines += result.counts.lines;
            stat.blank += result.counts.blank;
            stat.comment += result.counts.comment;
            stat.code += result.counts.code;
        }

        self.tasks.clearRetainingCapacity();
        self.results.clearRetainingCapacity();
    }

    fn deinit(self: *Batcher) void {
        for (self.tasks.items) |task| self.gpa.free(task.path);
        self.tasks.deinit(self.gpa);
        self.results.deinit(self.gpa);
    }
};

fn run(init: std.process.Init, config: Config) !void {
    const gpa = init.gpa;
    const io = init.io;

    const stats = try gpa.alloc(format.Summary, languages.languages.len);
    defer gpa.free(stats);
    for (stats, 0..) |*stat, index| {
        stat.* = .{ .lang = @intCast(index) };
    }

    var batcher = Batcher{
        .gpa = gpa,
        .io = io,
        .workers = config.workers,
        .stats = stats,
    };
    defer batcher.deinit();

    for (config.paths) |path| {
        walkRoot(gpa, io, &config, path, &batcher) catch |err| {
            std.log.err("kazu: {s}: {}", .{ path, err });
        };
    }
    try batcher.flush();

    var rows: std.ArrayList(format.Summary) = .empty;
    defer rows.deinit(gpa);
    for (stats) |stat| {
        if (stat.files == 0) continue;
        try rows.append(gpa, stat);
    }

    format.sortRows(rows.items, config.sort);
    const totals = format.total(rows.items);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &write_buffer);
    try format.writeReport(&writer.interface, config.format, rows.items, totals);
    try writer.interface.flush();
}

fn batchWorker(
    io: std.Io,
    gpa: std.mem.Allocator,
    tasks: []const FileTask,
    results: []?FileResult,
    next: *std.atomic.Value(usize),
) std.Io.Cancelable!void {
    const buffer = gpa.alloc(u8, read_buffer_size) catch |err| {
        std.log.err("kazu: cannot allocate read buffer: {}", .{err});
        return;
    };
    defer gpa.free(buffer);

    while (true) {
        const index = next.fetchAdd(1, .monotonic);
        if (index >= tasks.len) return;

        const task = tasks[index];
        const result = processFile(io, task, buffer) catch |err| {
            std.log.debug("kazu: skipping {s}: {}", .{ task.path, err });
            continue;
        };
        results[index] = result;
    }
}

fn processFile(
    io: std.Io,
    task: FileTask,
    buffer: []u8,
) !?FileResult {
    const file = try std.Io.Dir.cwd().openFile(io, task.path, .{});
    defer file.close(io);

    var lang_index = task.lang;
    if (lang_index == null) {
        var head: [512]u8 = undefined;
        const head_len = try file.readPositional(io, &.{head[0..]}, 0);
        lang_index = languages.detectShebang(head[0..head_len]) orelse return null;
    }

    const size = (try file.stat(io)).size;
    if (size > max_file_size) {
        std.log.warn("kazu: skipping {s}: file is larger than 256 MiB", .{task.path});
        return null;
    }

    var counter = count.Counter.init(&languages.languages[lang_index.?]);
    var offset: u64 = 0;
    while (true) {
        const read_len = try file.readPositional(io, &.{buffer}, offset);
        if (read_len == 0) break;
        offset += read_len;
        counter.feed(buffer[0..read_len]);
    }

    return .{ .lang = lang_index.?, .counts = counter.finish() };
}

fn walkRoot(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    path: []const u8,
    batcher: *Batcher,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        std.log.err("kazu: cannot access {s}: {}", .{ path, err });
        return;
    };

    switch (stat.kind) {
        .directory => {
            var root = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
                std.log.warn("kazu: cannot open directory {s}: {}", .{ path, err });
                return;
            };
            defer root.close(io);
            try walkDir(io, gpa, config, path, root, batcher);
        },
        .file => {
            const owned = try gpa.dupe(u8, path);
            try queueFile(gpa, config, std.fs.path.basename(path), owned, batcher);
        },
        else => std.log.warn("kazu: skipping {s}: not a regular file or directory", .{path}),
    }
}

fn walkDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *const Config,
    root_path: []const u8,
    root: std.Io.Dir,
    batcher: *Batcher,
) !void {
    var ignores = gitignore.Set.init(gpa);
    defer ignores.deinit();

    // Depth (relative to `root`) of each directory whose `.gitignore` is
    // currently loaded.  The root directory itself is depth 0.
    var ignore_depths: std.ArrayList(usize) = .empty;
    defer ignore_depths.deinit(gpa);

    if (config.gitignore) {
        _ = pushGitignore(
            gpa,
            io,
            root,
            ".gitignore",
            "",
            0,
            root_path,
            &ignores,
            &ignore_depths,
        );
    }

    var walker = try std.Io.Dir.walkSelectively(root, gpa);
    defer walker.deinit();

    var gitignore_path_buffer: [std.fs.max_path_bytes]u8 = undefined;

    while (true) {
        const maybe_entry = walker.next(io) catch |err| {
            // `next` pops the directory that failed, so the walk can continue.
            std.log.warn("kazu: cannot read directory: {}", .{err});
            continue;
        };
        const entry = maybe_entry orelse break;

        const depth = entry.depth();

        // The selective walker pops exhausted directories without notifying the
        // caller.  Use the depth of the entry we just received to drop any
        // `.gitignore` files that no longer apply.
        while (ignore_depths.items.len > 0 and
            ignore_depths.items[ignore_depths.items.len - 1] >= depth)
        {
            _ = ignore_depths.pop();
            ignores.pop();
        }

        switch (entry.kind) {
            .directory => {
                // Prune before opening: the walker only descends when we call
                // `enter`, so skipped trees cost a single readdir entry.
                if (isExcludedDir(config, entry.basename)) continue;
                if (ignores.isIgnored(entry.path, true)) continue;

                var pushed_ignore = false;
                if (config.gitignore) {
                    const sub_path = std.fmt.bufPrint(
                        &gitignore_path_buffer,
                        "{s}/.gitignore",
                        .{entry.basename},
                    ) catch null;
                    if (sub_path) |name| {
                        pushed_ignore = pushGitignore(
                            gpa,
                            io,
                            entry.dir,
                            name,
                            entry.path,
                            depth,
                            entry.path,
                            &ignores,
                            &ignore_depths,
                        );
                    }
                }

                walker.enter(io, entry) catch |err| {
                    if (pushed_ignore) {
                        _ = ignore_depths.pop();
                        ignores.pop();
                    }
                    std.log.warn("kazu: cannot open directory {s}: {}", .{ entry.path, err });
                    continue;
                };
            },
            .file, .unknown => {
                if (ignores.isIgnored(entry.path, false)) continue;
                const child = try std.fs.path.join(gpa, &.{ root_path, entry.path });
                try queueFile(gpa, config, entry.basename, child, batcher);
            },
            else => {},
        }
    }
}

/// Load `<dir>/<sub_path>` into `ignores`, remembering its depth so it can be
/// popped when the walk returns to an ancestor.  Returns true when a file was
/// added.  Missing, unreadable, oversized, empty or invalid files are ignored.
fn pushGitignore(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    base: []const u8,
    depth: usize,
    log_path: []const u8,
    ignores: *gitignore.Set,
    ignore_depths: *std.ArrayList(usize),
) bool {
    const contents = readGitignore(gpa, io, dir, sub_path) orelse return false;

    ignores.addOwned(base, contents) catch |err| {
        std.log.debug("kazu: cannot parse .gitignore in {s}: {}", .{ log_path, err });
        return false;
    };
    ignore_depths.append(gpa, depth) catch {
        ignores.pop();
        return false;
    };
    return true;
}

/// Read `.gitignore` from `dir`.  Missing, unreadable, oversized or empty
/// files simply produce null.
fn readGitignore(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) ?[]u8 {
    const file = dir.openFile(io, sub_path, .{}) catch return null;
    defer file.close(io);

    var contents: std.ArrayList(u8) = .empty;
    var keep = false;
    defer if (!keep) contents.deinit(gpa);

    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const read_len = file.readPositional(io, &.{buffer[0..]}, offset) catch return null;
        if (read_len == 0) break;
        if (contents.items.len + read_len > max_gitignore_size) return null;
        contents.appendSlice(gpa, buffer[0..read_len]) catch return null;
        offset += @intCast(read_len);
    }

    const owned = contents.toOwnedSlice(gpa) catch return null;
    keep = true;
    return owned;
}

/// Takes ownership of `path`, freeing it if the file is not queued.  On a
/// successful hand-off the batch owns the path and frees it after counting.
fn queueFile(
    gpa: std.mem.Allocator,
    config: *const Config,
    name: []const u8,
    path: []const u8,
    batcher: *Batcher,
) !void {
    if (!isIncludedFile(config, name)) {
        gpa.free(path);
        return;
    }

    const lang = languages.detectName(name);
    if (lang == null and !canHaveShebang(name)) {
        gpa.free(path);
        return;
    }

    try batcher.push(.{ .path = path, .lang = lang });
}

fn isExcludedDir(config: *const Config, name: []const u8) bool {
    for (config.exclude_dirs) |excluded| {
        if (std.mem.eql(u8, name, excluded)) return true;
    }
    return false;
}

fn extensionOf(name: []const u8) []const u8 {
    const extension = std.fs.path.extension(name);
    return if (extension.len > 1) extension[1..] else "";
}

fn hasExtension(list: []const []const u8, extension: []const u8) bool {
    if (extension.len == 0) return false;
    for (list) |candidate| {
        const expected = if (candidate.len > 0 and candidate[0] == '.') candidate[1..] else candidate;
        if (std.ascii.eqlIgnoreCase(extension, expected)) return true;
    }
    return false;
}

fn isIncludedFile(config: *const Config, name: []const u8) bool {
    const extension = extensionOf(name);

    if (config.include_exts.len > 0 and !hasExtension(config.include_exts, extension)) {
        return false;
    }
    if (hasExtension(config.exclude_exts, extension)) {
        return false;
    }
    return true;
}

fn canHaveShebang(name: []const u8) bool {
    return std.fs.path.extension(std.fs.path.basename(name)).len == 0;
}

test "gitignore is enabled by default and can be disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const default_action = try parseArgs(allocator, &.{ "kazu", "." });
    const default_config = switch (default_action) {
        .run => |config| config,
        else => unreachable,
    };
    try std.testing.expect(default_config.gitignore);

    const disabled_action = try parseArgs(allocator, &.{ "kazu", "--no-gitignore", "." });
    const disabled_config = switch (disabled_action) {
        .run => |config| config,
        else => unreachable,
    };
    try std.testing.expect(!disabled_config.gitignore);
}
