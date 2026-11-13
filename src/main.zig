//! kazu - fast parallel source code counter.
//!
//! Directory walking is sequential and uses `std.Io.Dir.walkSelectively`, so
//! excluded and ignored directories can be pruned before they are opened.
//! File paths are collected in two alternating batch slots, so the walker can
//! fill the next batch while the previous one is counted. Each batch is split
//! across a group of `std.Io` workers with one atomic counter. Every file and
//! directory operation goes through `std.Io`; its threaded backend runs the
//! syscall inline in the calling thread.

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
const max_ignore_size: usize = 1024 * 1024;
/// Files are counted in chunks so a worker never allocates a buffer the size
/// of the file.  One buffer is allocated per worker and reused for every file.
const read_buffer_size: usize = 64 * 1024;
/// `scc` treats a file as binary when a NUL byte appears in its first 10,000
/// bytes; grep, git and ripgrep use the same heuristic.  Binary files are not
/// counted.
const binary_scan_limit: u64 = 10_000;

const default_excluded_dirs = [_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "zig-cache",
    ".zig-cache",
    "zig-out",
    "zig-pkg",
    "__pycache__",
    ".venv",
    "venv",
    "target",
};

/// Lockfiles are generated dependency data, not source.  These names match
/// `scc`'s default `--exclude-file` list, and like `scc` the match is a
/// substring of the basename.
const default_excluded_files = [_][]const u8{
    "package-lock.json",
    "Cargo.lock",
    "yarn.lock",
    "pubspec.lock",
    "Podfile.lock",
    "pnpm-lock.yaml",
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
    \\      --by-file             Show one row per file instead of per language
    \\      --include-symlinks    Count symlinked files (off by default)
    \\      --exclude-dir <name>  Skip a directory name (repeatable)
    \\      --include-ext <ext>   Only count these extensions (repeatable)
    \\      --exclude-ext <ext>   Skip these extensions (repeatable)
    \\      --no-gitignore        Do not read .gitignore files
    \\      --no-ignore           Do not read .ignore files
    \\  -h, --help                Show this help
    \\  -v, --version             Show the version
    \\
    \\With no paths, the current directory is scanned. Language is detected from
    \\the file name, extension, or a #! interpreter line. Lines are classified as
    \\code, comment, or blank; mixed code/comment lines count as code.
    \\
    \\.gitignore and .ignore files are honored by default; use --no-gitignore or
    \\--no-ignore to disable them individually.
    \\Binary files are skipped; symlinks are only counted with --include-symlinks.
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
    ignore: bool = true,
    by_file: bool = false,
    include_symlinks: bool = false,
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

/// Remembers which files have already been counted so a symlink that resolves
/// to a file in the tree is not counted twice, matching `scc`.  Keys are
/// canonical paths: walked files use `<root real path>/<relative path>` and
/// symlinks use their resolved target, so both spell the same file the same
/// way.  Only allocated when `--include-symlinks` is set.
const SymlinkDedup = struct {
    arena: std.heap.ArenaAllocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Canonical path of the directory currently being walked.
    root_real: []const u8 = "",

    fn init(gpa: std.mem.Allocator) SymlinkDedup {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *SymlinkDedup) void {
        self.seen.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    fn contains(self: *const SymlinkDedup, key: []const u8) bool {
        return self.seen.contains(key);
    }

    fn insert(self: *SymlinkDedup, key: []const u8) !void {
        const allocator = self.arena.allocator();
        const owned = try allocator.dupe(u8, key);
        try self.seen.put(allocator, owned, {});
    }

    /// Canonical key for a path relative to the walk root, formatted into
    /// `buffer`.  Returns null when the root has no canonical path.
    fn relativeKey(
        self: *const SymlinkDedup,
        relative: []const u8,
        buffer: []u8,
    ) ?[]const u8 {
        if (self.root_real.len == 0) return null;
        const separator: []const u8 = if (self.root_real[self.root_real.len - 1] == '/') "" else "/";
        return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ self.root_real, separator, relative }) catch null;
    }

    fn containsRelative(self: *const SymlinkDedup, relative: []const u8, buffer: []u8) bool {
        const key = self.relativeKey(relative, buffer) orelse return false;
        return self.contains(key);
    }

    fn insertRelative(self: *SymlinkDedup, relative: []const u8, buffer: []u8) !void {
        const key = self.relativeKey(relative, buffer) orelse return;
        try self.insert(key);
    }
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
    var use_ignore = true;
    var by_file = false;
    var include_symlinks = false;
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
        } else if (std.mem.eql(u8, option.name, "--by-file")) {
            by_file = true;
        } else if (std.mem.eql(u8, option.name, "--include-symlinks")) {
            include_symlinks = true;
        } else if (std.mem.eql(u8, option.name, "--no-gitignore")) {
            use_gitignore = false;
        } else if (std.mem.eql(u8, option.name, "--no-ignore")) {
            use_ignore = false;
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
        .ignore = use_ignore,
        .by_file = by_file,
        .include_symlinks = include_symlinks,
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
/// batch is split dynamically with one atomic counter.  Two batch slots let the
/// walker fill the next batch while the previous one is counted.
const Batcher = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    workers: usize,
    stats: []format.Summary,
    /// When set, each counted file is retained for `--by-file` output and the
    /// batch hands ownership of the path to this list instead of freeing it.
    files: ?*std.ArrayList(format.FileSummary) = null,
    slots: [2]BatchSlot = .{ .{}, .{} },
    current: usize = 0,
    group: std.Io.Group = .init,

    const BatchSlot = struct {
        tasks: std.ArrayList(FileTask) = .empty,
        results: std.ArrayList(?FileResult) = .empty,
        /// Lives with the slot because workers can outlive `start`.
        next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        pending: bool = false,
    };

    /// Takes ownership of `task.path` even when an error is returned.
    fn push(self: *Batcher, task: FileTask) !void {
        const slot = &self.slots[self.current];
        slot.tasks.append(self.gpa, task) catch |err| {
            self.gpa.free(task.path);
            return err;
        };
        if (slot.tasks.items.len >= batch_size) try self.dispatch();
    }

    /// Start counting the current slot, then switch to the other slot so the
    /// walker can fill it while this batch runs.  The previous batch must be
    /// finished before its slot can be reused.
    fn dispatch(self: *Batcher) !void {
        const index = self.current;
        if (self.slots[index].tasks.items.len == 0) return;

        const other = 1 - index;
        if (self.slots[other].pending) {
            try self.group.await(self.io);
            self.fold(other);
            self.slots[other].pending = false;
        }

        try self.start(index);
        self.slots[index].pending = true;
        self.current = other;
    }

    fn start(self: *Batcher, index: usize) !void {
        const slot = &self.slots[index];
        try slot.results.resize(self.gpa, slot.tasks.items.len);
        @memset(slot.results.items, null);

        // Reserve room up front so a successful count can always move its path
        // into the per-file list without a second allocation.
        if (self.files) |files| try files.ensureUnusedCapacity(self.gpa, slot.tasks.items.len);

        slot.next = std.atomic.Value(usize).init(0);
        var spawned: usize = 0;
        const wanted = @min(self.workers, slot.tasks.items.len);
        while (spawned < wanted) : (spawned += 1) {
            // A failed spawn is fine as long as at least one worker runs: the
            // shared counter keeps every worker busy until the batch is empty.
            self.group.concurrent(self.io, batchWorker, .{
                self.io,
                self.gpa,
                slot.tasks.items,
                slot.results.items,
                &slot.next,
            }) catch break;
        }
        if (spawned == 0) {
            // No concurrency available (for example a single-threaded `Io`
            // implementation); count the batch on this thread.
            batchWorker(self.io, self.gpa, slot.tasks.items, slot.results.items, &slot.next) catch {};
        }
    }

    fn fold(self: *Batcher, index: usize) void {
        const slot = &self.slots[index];
        for (slot.tasks.items, slot.results.items) |task, maybe_result| {
            const result = maybe_result orelse {
                self.gpa.free(task.path);
                continue;
            };

            if (self.files) |files| {
                files.appendAssumeCapacity(.{
                    .path = task.path,
                    .lang = result.lang,
                    .lines = result.counts.lines,
                    .blank = result.counts.blank,
                    .comment = result.counts.comment,
                    .code = result.counts.code,
                });
            } else {
                self.gpa.free(task.path);
            }

            const stat = &self.stats[result.lang];
            stat.files += 1;
            stat.lines += result.counts.lines;
            stat.blank += result.counts.blank;
            stat.comment += result.counts.comment;
            stat.code += result.counts.code;
        }

        slot.tasks.clearRetainingCapacity();
        slot.results.clearRetainingCapacity();
    }

    fn flush(self: *Batcher) !void {
        // Finish a batch dispatched by `push` before starting the tail batch.
        // Keeping at most one un-folded batch alive also keeps the per-file
        // list's reserved capacity valid.
        const index = self.current;
        const other = 1 - index;
        if (self.slots[other].pending) {
            try self.group.await(self.io);
            self.fold(other);
            self.slots[other].pending = false;
        }

        if (self.slots[index].tasks.items.len > 0) {
            try self.start(index);
            self.slots[index].pending = true;
            try self.group.await(self.io);
            self.fold(index);
            self.slots[index].pending = false;
        }
    }

    /// Wait for every dispatched batch and fold its results.  Used by `deinit`
    /// when an error skipped `flush`.
    fn finishPending(self: *Batcher) void {
        self.group.await(self.io) catch {};
        for (0..self.slots.len) |i| {
            if (self.slots[i].pending) {
                self.fold(i);
                self.slots[i].pending = false;
            }
        }
    }

    fn deinit(self: *Batcher) void {
        self.finishPending();
        for (&self.slots) |*slot| {
            for (slot.tasks.items) |task| self.gpa.free(task.path);
            slot.tasks.deinit(self.gpa);
            slot.results.deinit(self.gpa);
        }
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

    // In per-file mode the batcher transfers ownership of each counted path
    // here instead of freeing it, so this list must release them.
    var files: std.ArrayList(format.FileSummary) = .empty;
    defer {
        for (files.items) |file| gpa.free(file.path);
        files.deinit(gpa);
    }

    var batcher = Batcher{
        .gpa = gpa,
        .io = io,
        .workers = config.workers,
        .stats = stats,
        .files = if (config.by_file) &files else null,
    };
    defer batcher.deinit();

    var dedup = SymlinkDedup.init(gpa);
    defer dedup.deinit();
    const dedup_ptr: ?*SymlinkDedup = if (config.include_symlinks) &dedup else null;

    for (config.paths) |path| {
        walkRoot(gpa, io, &config, path, dedup_ptr, &batcher) catch |err| {
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
    format.sortFiles(files.items, config.sort);
    const totals = format.total(rows.items);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &write_buffer);
    try format.writeReport(&writer.interface, config.format, rows.items, if (config.by_file) files.items else null, totals);
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

    var counter = count.Counter.init(&languages.languages[lang_index.?]);
    var offset: u64 = 0;
    var size_checked = false;
    while (true) {
        const read_len = try file.readPositional(io, &.{buffer}, offset);
        if (read_len == 0) break;
        if (isBinaryChunk(buffer[0..read_len], offset)) {
            std.log.debug("kazu: skipping {s}: binary file", .{task.path});
            return null;
        }
        // Only a file that fills the first read can exceed the size limit, so
        // the common small-file case never pays for a stat.
        if (!size_checked and read_len == buffer.len) {
            size_checked = true;
            if ((try file.stat(io)).size > max_file_size) {
                std.log.warn("kazu: skipping {s}: file is larger than 256 MiB", .{task.path});
                return null;
            }
        }
        offset += read_len;
        if (offset > max_file_size) {
            std.log.warn("kazu: skipping {s}: file is larger than 256 MiB", .{task.path});
            return null;
        }
        counter.feed(buffer[0..read_len]);
    }

    return .{ .lang = lang_index.?, .counts = counter.finish() };
}

/// A NUL byte in the first 10,000 bytes marks the file as binary.  The check is
/// limited so text files that happen to contain a NUL later are still counted,
/// exactly like `scc`.
fn isBinaryChunk(chunk: []const u8, offset: u64) bool {
    if (offset >= binary_scan_limit) return false;
    const remaining: usize = @intCast(binary_scan_limit - offset);
    return std.mem.indexOfScalar(u8, chunk[0..@min(chunk.len, remaining)], 0) != null;
}

fn walkRoot(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    path: []const u8,
    dedup: ?*SymlinkDedup,
    batcher: *Batcher,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
        std.log.err("kazu: cannot access {s}: {}", .{ path, err });
        return;
    };

    var kind = stat.kind;
    if (kind == .sym_link) {
        if (!config.include_symlinks) {
            std.log.warn("kazu: skipping {s}: symlink (use --include-symlinks)", .{path});
            return;
        }
        // An explicit symlink root is followed, like `scc`; the walk itself
        // still never descends into symlinked directories.
        const target = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch |err| {
            std.log.warn("kazu: cannot follow symlink {s}: {}", .{ path, err });
            return;
        };
        kind = target.kind;
    }

    switch (kind) {
        .directory => {
            var root = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
                std.log.warn("kazu: cannot open directory {s}: {}", .{ path, err });
                return;
            };
            defer root.close(io);

            // Canonical root so walked files and resolved symlinks produce the
            // same dedup key.
            var root_real_buffer: [std.fs.max_path_bytes]u8 = undefined;
            var walk_dedup = dedup;
            if (dedup) |seen| {
                const n = std.Io.Dir.cwd().realPathFile(io, path, &root_real_buffer) catch 0;
                if (n > 0) {
                    seen.root_real = root_real_buffer[0..n];
                } else {
                    walk_dedup = null;
                }
            }

            try walkDir(io, gpa, config, path, root, walk_dedup, batcher);
        },
        .file => {
            const owned = try gpa.dupe(u8, path);
            if (dedup) |seen| {
                var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const n = std.Io.Dir.cwd().realPathFile(io, path, &key_buffer) catch 0;
                if (n > 0) {
                    const key = key_buffer[0..n];
                    if (seen.contains(key)) {
                        gpa.free(owned);
                        return;
                    }
                    if (try queueFile(gpa, config, std.fs.path.basename(path), owned, batcher)) {
                        try seen.insert(key);
                    }
                    return;
                }
            }
            _ = try queueFile(gpa, config, std.fs.path.basename(path), owned, batcher);
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
    dedup: ?*SymlinkDedup,
    batcher: *Batcher,
) !void {
    var ignores = gitignore.Set.init(gpa);
    defer ignores.deinit();

    // Depth (relative to `root`) of each directory whose ignore file is
    // currently loaded.  The root directory itself is depth 0.
    var ignore_depths: std.ArrayList(usize) = .empty;
    defer ignore_depths.deinit(gpa);

    _ = pushIgnoreFiles(
        gpa,
        io,
        config,
        root,
        "",
        0,
        root_path,
        &ignores,
        &ignore_depths,
    );

    var walker = try std.Io.Dir.walkSelectively(root, gpa);
    defer walker.deinit();

    while (true) {
        const maybe_entry = walker.next(io) catch |err| {
            // `next` pops the directory that failed, so the walk can continue.
            std.log.warn("kazu: cannot read directory: {}", .{err});
            continue;
        };
        const entry = maybe_entry orelse break;

        const depth = entry.depth();

        // Readdir may report `unknown` on filesystems without d_type.  Resolve
        // it without following symlinks so directories are still entered and
        // non-regular files (FIFOs, sockets, devices) are skipped.
        var effective = entry;
        if (entry.kind == .unknown) {
            const stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |err| {
                std.log.warn("kazu: cannot stat {s}: {}", .{ entry.path, err });
                continue;
            };
            effective.kind = stat.kind;
        }

        // The selective walker pops exhausted directories without notifying the
        // caller.  Use the depth of the entry we just received to drop any
        // ignore files that no longer apply.
        while (ignore_depths.items.len > 0 and
            ignore_depths.items[ignore_depths.items.len - 1] >= depth)
        {
            _ = ignore_depths.pop();
            ignores.pop();
        }

        switch (effective.kind) {
            .directory => {
                // Prune before opening: the walker only descends when we call
                // `enter`, so skipped trees cost a single readdir entry.
                if (isExcludedDir(config, entry.basename)) continue;
                if (ignores.isIgnored(entry.path, true)) continue;

                var pushed_ignore: usize = 0;
                pushed_ignore = pushIgnoreFiles(
                    gpa,
                    io,
                    config,
                    entry.dir,
                    entry.basename,
                    depth,
                    entry.path,
                    &ignores,
                    &ignore_depths,
                );

                walker.enter(io, effective) catch |err| {
                    var remaining = pushed_ignore;
                    while (remaining > 0) : (remaining -= 1) {
                        _ = ignore_depths.pop();
                        ignores.pop();
                    }
                    std.log.warn("kazu: cannot open directory {s}: {}", .{ entry.path, err });
                    continue;
                };
            },
            .file => {
                if (ignores.isIgnored(entry.path, false)) continue;
                const child = try std.fs.path.join(gpa, &.{ root_path, entry.path });
                try queueWalked(gpa, config, dedup, entry.path, entry.basename, child, batcher);
            },
            .sym_link => {
                // Symlinked directories are not followed: that risks cycles
                // and differs from `scc`, whose walk only counts symlinked
                // files.  An explicit symlink root is still followed.
                if (!config.include_symlinks) continue;
                if (ignores.isIgnored(entry.path, false)) continue;

                const target = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = true }) catch |err| {
                    std.log.debug("kazu: skipping symlink {s}: {}", .{ entry.path, err });
                    continue;
                };
                if (target.kind != .file) continue;

                const child = try std.fs.path.join(gpa, &.{ root_path, entry.path });

                // Key the target's canonical path so a link that resolves to a
                // file already counted is skipped.
                var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const key_len = entry.dir.realPathFile(io, entry.basename, &key_buffer) catch 0;
                const key: ?[]const u8 = if (key_len > 0) key_buffer[0..key_len] else null;

                if (dedup) |seen| {
                    if (key) |canonical| {
                        if (seen.contains(canonical)) {
                            gpa.free(child);
                            continue;
                        }
                    }
                }

                if (try queueFile(gpa, config, entry.basename, child, batcher)) {
                    if (dedup) |seen| {
                        if (key) |canonical| try seen.insert(canonical);
                    }
                }
            },
            else => {},
        }
    }
}

/// Load the ignore files in one directory: `.gitignore` first, then `.ignore`,
/// so `.ignore` rules win when both match.  Each loaded file is recorded at
/// `depth` so it can be popped when the walk returns to an ancestor.  Returns
/// the number of files added.
fn pushIgnoreFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    dir: std.Io.Dir,
    base: []const u8,
    depth: usize,
    log_path: []const u8,
    ignores: *gitignore.Set,
    ignore_depths: *std.ArrayList(usize),
) usize {
    var pushed: usize = 0;
    if (config.gitignore and pushIgnoreFile(
        gpa,
        io,
        dir,
        base,
        ".gitignore",
        depth,
        log_path,
        ignores,
        ignore_depths,
    )) pushed += 1;
    if (config.ignore and pushIgnoreFile(
        gpa,
        io,
        dir,
        base,
        ".ignore",
        depth,
        log_path,
        ignores,
        ignore_depths,
    )) pushed += 1;
    return pushed;
}

/// Load `<dir>/<base>/<name>` into `ignores`, remembering its depth so it can
/// be popped when the walk returns to an ancestor.  Returns true when a file
/// was added.  Missing, unreadable, oversized, empty or invalid files are
/// ignored.
fn pushIgnoreFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    base: []const u8,
    name: []const u8,
    depth: usize,
    log_path: []const u8,
    ignores: *gitignore.Set,
    ignore_depths: *std.ArrayList(usize),
) bool {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sub_path = if (base.len == 0)
        name
    else
        std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ base, name }) catch return false;

    const contents = readIgnoreFile(gpa, io, dir, sub_path) orelse return false;

    ignores.addOwned(base, contents) catch |err| {
        std.log.debug("kazu: cannot parse {s} in {s}: {}", .{ name, log_path, err });
        return false;
    };
    ignore_depths.append(gpa, depth) catch {
        ignores.pop();
        return false;
    };
    return true;
}

/// Read an ignore file from `dir`.  Missing, unreadable, oversized or empty
/// files simply produce null.
fn readIgnoreFile(
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
        if (contents.items.len + read_len > max_ignore_size) return null;
        contents.appendSlice(gpa, buffer[0..read_len]) catch return null;
        offset += @intCast(read_len);
    }

    const owned = contents.toOwnedSlice(gpa) catch return null;
    keep = true;
    return owned;
}

/// Queues a regular file found by the walk.  When symlink support is on, the
/// canonical walk path is checked first so a file that was already counted
/// through a symlink is not counted again.
fn queueWalked(
    gpa: std.mem.Allocator,
    config: *const Config,
    dedup: ?*SymlinkDedup,
    relative: []const u8,
    name: []const u8,
    path: []const u8,
    batcher: *Batcher,
) !void {
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;

    if (dedup) |seen| {
        if (seen.containsRelative(relative, &key_buffer)) {
            gpa.free(path);
            return;
        }
    }

    if (try queueFile(gpa, config, name, path, batcher)) {
        if (dedup) |seen| try seen.insertRelative(relative, &key_buffer);
    }
}

/// Takes ownership of `path`, freeing it if the file is not queued.  On a
/// successful hand-off the batch owns the path and frees it after counting.
/// Returns whether the file was queued.
fn queueFile(
    gpa: std.mem.Allocator,
    config: *const Config,
    name: []const u8,
    path: []const u8,
    batcher: *Batcher,
) !bool {
    if (!isIncludedFile(config, name)) {
        gpa.free(path);
        return false;
    }

    const lang = languages.detectBasename(name);
    if (lang == null and !canHaveShebang(name)) {
        gpa.free(path);
        return false;
    }

    try batcher.push(.{ .path = path, .lang = lang });
    return true;
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
    // `.gitignore` and `.ignore` are read for their rules, but they are
    // metadata rather than source, so they are not counted.  `scc` does the
    // same; `.dockerignore` is still reported as "Docker ignore".
    if (std.mem.eql(u8, name, ".gitignore") or std.mem.eql(u8, name, ".ignore")) {
        return false;
    }

    for (default_excluded_files) |excluded| {
        if (std.mem.indexOf(u8, name, excluded) != null) return false;
    }

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

test "gitignore and ignore are enabled by default and can be disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const default_action = try parseArgs(allocator, &.{ "kazu", "." });
    const default_config = switch (default_action) {
        .run => |config| config,
        else => unreachable,
    };
    try std.testing.expect(default_config.gitignore);
    try std.testing.expect(default_config.ignore);

    const no_gitignore_action = try parseArgs(allocator, &.{ "kazu", "--no-gitignore", "." });
    const no_gitignore_config = switch (no_gitignore_action) {
        .run => |config| config,
        else => unreachable,
    };
    try std.testing.expect(!no_gitignore_config.gitignore);
    try std.testing.expect(no_gitignore_config.ignore);

    const no_ignore_action = try parseArgs(allocator, &.{ "kazu", "--no-ignore", "." });
    const no_ignore_config = switch (no_ignore_action) {
        .run => |config| config,
        else => unreachable,
    };
    try std.testing.expect(no_ignore_config.gitignore);
    try std.testing.expect(!no_ignore_config.ignore);
}

test "gitignore and ignore files are read but not counted" {
    const config = Config{ .workers = 1 };

    try std.testing.expect(!isIncludedFile(&config, ".gitignore"));
    try std.testing.expect(!isIncludedFile(&config, ".ignore"));
    try std.testing.expect(isIncludedFile(&config, ".dockerignore"));
    try std.testing.expect(isIncludedFile(&config, "main.zig"));
}

/// Result of walking a temporary fixture in per-file mode.
const WalkFixture = struct {
    files: std.ArrayList(format.FileSummary),
    stats: []format.Summary,

    fn deinit(self: *WalkFixture, gpa: std.mem.Allocator) void {
        for (self.files.items) |file| gpa.free(file.path);
        self.files.deinit(gpa);
        gpa.free(self.stats);
    }

    fn has(self: *const WalkFixture, name: []const u8) bool {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, std.fs.path.basename(file.path), name)) return true;
        }
        return false;
    }
};

/// Walk a `std.testing.tmpDir` fixture through the real walker and batcher so
/// ignore-file handling is exercised end to end.
fn walkFixture(
    io: std.Io,
    gpa: std.mem.Allocator,
    config: Config,
    root_path: []const u8,
    root: std.Io.Dir,
) !WalkFixture {
    const stats = try gpa.alloc(format.Summary, languages.languages.len);
    for (stats, 0..) |*stat, index| stat.* = .{ .lang = @intCast(index) };

    var files: std.ArrayList(format.FileSummary) = .empty;
    var batcher = Batcher{
        .gpa = gpa,
        .io = io,
        .workers = 1,
        .stats = stats,
        .files = &files,
    };
    defer batcher.deinit();

    var mutable = config;
    try walkDir(io, gpa, &mutable, root_path, root, null, &batcher);
    try batcher.flush();
    return .{ .files = files, .stats = stats };
}

fn fixtureRootPath(gpa: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
}

test ".ignore rules are honored and the file is not counted" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".ignore", .data = "*.c\n!keep.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.c", .data = "int keep;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.c", .data = "int other;\n" });

    const root_path = try fixtureRootPath(gpa, &tmp);
    defer gpa.free(root_path);

    var result = try walkFixture(io, gpa, .{ .workers = 1 }, root_path, tmp.dir);
    defer result.deinit(gpa);

    try std.testing.expect(result.has("keep.c"));
    try std.testing.expect(!result.has("other.c"));
    try std.testing.expectEqual(@as(usize, 1), result.files.items.len);
}

test ".ignore overrides .gitignore and nested rules override parents" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ignore", .data = "!keep.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.c", .data = "int keep;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.c", .data = "int other;\n" });

    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/.ignore", .data = "!a.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/a.c", .data = "int a;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.c", .data = "int b;\n" });

    const root_path = try fixtureRootPath(gpa, &tmp);
    defer gpa.free(root_path);

    var result = try walkFixture(io, gpa, .{ .workers = 1 }, root_path, tmp.dir);
    defer result.deinit(gpa);

    try std.testing.expect(result.has("keep.c"));
    try std.testing.expect(!result.has("other.c"));
    try std.testing.expect(result.has("a.c"));
    try std.testing.expect(!result.has("b.c"));
    try std.testing.expectEqual(@as(usize, 2), result.files.items.len);
}

test "--no-ignore keeps .gitignore active" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ignore", .data = "!keep.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.c", .data = "int keep;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.c", .data = "int other;\n" });

    const root_path = try fixtureRootPath(gpa, &tmp);
    defer gpa.free(root_path);

    var enabled = try walkFixture(io, gpa, .{ .workers = 1 }, root_path, tmp.dir);
    defer enabled.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), enabled.files.items.len);
    try std.testing.expect(enabled.has("keep.c"));

    var disabled = try walkFixture(
        io,
        gpa,
        .{ .workers = 1, .ignore = false },
        root_path,
        tmp.dir,
    );
    defer disabled.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), disabled.files.items.len);
}

test "--no-gitignore keeps .ignore active" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ignore", .data = "skip.c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.c", .data = "int keep;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skip.c", .data = "int skip;\n" });

    const root_path = try fixtureRootPath(gpa, &tmp);
    defer gpa.free(root_path);

    var result = try walkFixture(
        io,
        gpa,
        .{ .workers = 1, .gitignore = false },
        root_path,
        tmp.dir,
    );
    defer result.deinit(gpa);

    try std.testing.expect(result.has("keep.c"));
    try std.testing.expect(!result.has("skip.c"));
    try std.testing.expectEqual(@as(usize, 1), result.files.items.len);
}

test "default lockfiles are not counted" {
    const config = Config{ .workers = 1 };

    for (default_excluded_files) |name| {
        try std.testing.expect(!isIncludedFile(&config, name));
    }
    // Matching is by substring, like scc's --exclude-file.
    try std.testing.expect(!isIncludedFile(&config, "my-package-lock.json"));
    try std.testing.expect(isIncludedFile(&config, "main.c"));
    try std.testing.expect(isIncludedFile(&config, "lockfile.json"));
}

test "by-file mode is parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const default_action = try parseArgs(allocator, &.{ "kazu", "." });
    const default_config = switch (default_action) {
        .run => |config| config,
        else => unreachable,
    };
    try std.testing.expect(!default_config.by_file);

    const action = try parseArgs(allocator, &.{ "kazu", "--by-file", "." });
    const config = switch (action) {
        .run => |value| value,
        else => unreachable,
    };
    try std.testing.expect(config.by_file);
}

test "include-symlinks is parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const default_action = try parseArgs(allocator, &.{ "kazu", "." });
    const default_config = switch (default_action) {
        .run => |config| config,
        else => unreachable,
    };
    try std.testing.expect(!default_config.include_symlinks);

    const action = try parseArgs(allocator, &.{ "kazu", "--include-symlinks", "." });
    const config = switch (action) {
        .run => |value| value,
        else => unreachable,
    };
    try std.testing.expect(config.include_symlinks);
}

test "binary detection only scans the first 10000 bytes" {
    try std.testing.expect(!isBinaryChunk("int x;\n", 0));
    try std.testing.expect(isBinaryChunk("abc\x00def", 0));

    var text: [10_016]u8 = @splat('a');
    try std.testing.expect(!isBinaryChunk(&text, 0));

    // A NUL at byte 10000 is outside the scanned prefix.
    text[10_000] = 0;
    try std.testing.expect(!isBinaryChunk(&text, 0));
    try std.testing.expect(!isBinaryChunk(text[9_990..], 9_990));
    try std.testing.expect(!isBinaryChunk(text[10_000..], 10_000));
    try std.testing.expect(!isBinaryChunk("\x00", 10_000));

    // The NUL is checked only while it falls inside the prefix.
    try std.testing.expect(!isBinaryChunk("ab\x00", 9_998));
    try std.testing.expect(isBinaryChunk("ab\x00", 9_997));
}

test "symlink dedup compares walked paths with resolved targets" {
    var dedup = SymlinkDedup.init(std.testing.allocator);
    defer dedup.deinit();
    dedup.root_real = "/tree";

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(!dedup.containsRelative("src/a.c", &buffer));

    try dedup.insertRelative("src/a.c", &buffer);
    try std.testing.expect(dedup.contains("/tree/src/a.c"));
    try std.testing.expect(dedup.containsRelative("src/a.c", &buffer));
    try std.testing.expect(!dedup.containsRelative("src/b.c", &buffer));

    // Two symlinks to the same outside target are counted once.
    try dedup.insert("/outside/lib.c");
    try std.testing.expect(dedup.contains("/outside/lib.c"));
}
