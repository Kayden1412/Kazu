//! Interleaved benchmark driver comparing kazu, scc, tokei, and mezura.
//! Build it with `zig build bench`.
//!
//! Every timed run spawns the tool directly with stdout and stderr discarded,
//! so the measured wall clock includes process startup but not a shell. Each
//! round runs the tools in a different order (forward, then reversed) so drift
//! and throttle episodes hit every tool equally.
//!
//! Timing comes from `wait4` rusage: wall clock is measured around the spawn,
//! CPU time is `ru_utime + ru_stime`, and peak RSS is `ru_maxrss` (KiB on
//! Linux). Reported timings are medians; mean, standard deviation, min, and
//! max are kept for context.
//!
//! Peak RSS needs a caveat. A forked child starts with the parent's resident
//! pages, and `ru_maxrss` counts them, so the measuring process must stay
//! small. That is why this driver streams each tool's JSON output instead of
//! buffering it, and it is why it replaced the Python implementation: the
//! interpreter added roughly 10-20 MiB of inherited RSS, which made every
//! small tool report the same peak memory.
//!
//! Each tool is run once more to read its reported totals (files, lines, code,
//! comments, blanks). That run is not timed: its stdout is parsed while it
//! streams, and its stderr is kept so a failed run can report the reason.
//!
//! Ignore files are honored by default. `--no-gitignore` disables them for
//! every tool, and `--by-file` asks each tool for per-file output where it has
//! one.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const default_rounds: usize = 7;
const default_timeout_s: f64 = 1800.0;
/// Probing `--version` should never take long, but a broken binary must not be
/// able to stall the report.
const version_timeout_s: f64 = 60.0;
/// One buffer per capture run; the JSON scanner refills it as needed, so the
/// driver never holds a tool's whole report in memory.
const read_buffer_size: usize = 64 * 1024;
const max_json_depth: usize = 128;
/// The watchdog re-checks `done` this often, so a finished run waits at most
/// one slice for the watchdog thread to exit. That wait happens after the
/// timestamps are taken, but it still adds to wall clock, so keep it short.
const watchdog_slice_ns: i96 = 10 * std.time.ns_per_ms;

const help_text =
    \\bench - interleaved benchmark driver for kazu, scc, tokei, and mezura
    \\
    \\Usage:
    \\  bench --repo NAME=PATH [options]
    \\
    \\Options:
    \\      --kazu PATH            kazu binary (default: kazu)
    \\      --kazu-base PATH       baseline kazu binary to compare against
    \\      --kazu-variant NAME=PATH
    \\                             extra kazu build to time alongside --kazu;
    \\                             NAME must start with "kazu" (repeatable)
    \\      --scc PATH             scc binary (default: scc)
    \\      --tokei PATH           tokei binary (default: tokei)
    \\      --mezura PATH          mezura binary (default: mezura)
    \\      --repo NAME=PATH       repository label and checkout path (repeatable)
    \\      --rounds N             timed rounds per tool (default: 7)
    \\      --workers N            kazu worker count (0 = CPU count)
    \\      --timeout SECONDS      per-run timeout (default: 1800)
    \\      --by-file              ask every tool for per-file output
    \\      --no-gitignore         disable ignore files for every tool
    \\      --describe NAME=TEXT   short description shown next to a version
    \\      --json PATH            write machine-readable results here
    \\      --markdown PATH        write a Markdown report here
    \\      --svg PATH             write a peak-memory chart here
    \\      --summary PATH         append the Markdown report to this file
    \\  -h, --help                 Show this help
    \\
;

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

const Run = struct {
    wall_ms: f64,
    cpu_ms: f64,
    maxrss_kb: u64,
};

const Counts = struct {
    files: u64 = 0,
    lines: u64 = 0,
    code: u64 = 0,
    comments: u64 = 0,
    blanks: u64 = 0,
};

const Stats = struct {
    n: usize,
    median: f64,
    mean: f64,
    stdev: f64,
    min: f64,
    max: f64,
};

const Summary = struct {
    err: ?[]const u8 = null,
    wall: ?Stats = null,
    cpu: ?Stats = null,
    rss: ?Stats = null,
    counts: ?Counts = null,
};

const RepoResult = struct {
    label: []const u8,
    path: []const u8,
    /// Parallel to `Report.tools`.
    summaries: []Summary,
    err: ?[]const u8 = null,
};

const ToolKind = enum { kazu, scc, tokei, mezura };

const Tool = struct {
    name: []const u8,
    path: []const u8,
    kind: ToolKind,
    version: []const u8 = "unknown",
    description: ?[]const u8 = null,
};

const Options = struct {
    by_file: bool = false,
    no_gitignore: bool = false,
};

const Report = struct {
    generated_at: []const u8,
    rounds: usize,
    workers: usize,
    options: Options,
    tools: []const Tool,
    repos: []const RepoResult,
};

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

const Config = struct {
    kazu: []const u8 = "kazu",
    kazu_base: []const u8 = "",
    kazu_variants: std.ArrayList([]const u8) = .empty,
    scc: []const u8 = "scc",
    tokei: []const u8 = "tokei",
    mezura: []const u8 = "mezura",
    repos: std.ArrayList([]const u8) = .empty,
    rounds: usize = default_rounds,
    workers: usize = 0,
    by_file: bool = false,
    no_gitignore: bool = false,
    timeout_s: f64 = default_timeout_s,
    describes: std.ArrayList([]const u8) = .empty,
    json_path: ?[]const u8 = null,
    markdown_path: ?[]const u8 = null,
    svg_path: ?[]const u8 = null,
    summary_path: ?[]const u8 = null,
};

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

fn optionValue(option: Option, args: []const []const u8, index: *usize) ?[]const u8 {
    if (option.value) |value| return value;
    if (index.* + 1 >= args.len) return null;
    index.* += 1;
    return args[index.*];
}

fn invalid(comptime message: []const u8, args: anytype) error{InvalidArgs} {
    std.debug.print("bench: " ++ message ++ "\n", args);
    std.debug.print("Try 'bench --help' for more information.\n", .{});
    return error.InvalidArgs;
}

fn parseArgs(arena: Allocator, args: []const []const u8) !Config {
    var config: Config = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const option = splitOption(arg);

        if (std.mem.eql(u8, option.name, "--kazu")) {
            config.kazu = optionValue(option, args, &i) orelse
                return invalid("--kazu requires a value", .{});
        } else if (std.mem.eql(u8, option.name, "--kazu-base")) {
            config.kazu_base = optionValue(option, args, &i) orelse
                return invalid("--kazu-base requires a value", .{});
        } else if (std.mem.eql(u8, option.name, "--kazu-variant")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("--kazu-variant requires NAME=PATH", .{});
            try config.kazu_variants.append(arena, value);
        } else if (std.mem.eql(u8, option.name, "--scc")) {
            config.scc = optionValue(option, args, &i) orelse
                return invalid("--scc requires a value", .{});
        } else if (std.mem.eql(u8, option.name, "--tokei")) {
            config.tokei = optionValue(option, args, &i) orelse
                return invalid("--tokei requires a value", .{});
        } else if (std.mem.eql(u8, option.name, "--mezura")) {
            config.mezura = optionValue(option, args, &i) orelse
                return invalid("--mezura requires a value", .{});
        } else if (std.mem.eql(u8, option.name, "--repo")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("--repo requires NAME=PATH", .{});
            try config.repos.append(arena, value);
        } else if (std.mem.eql(u8, option.name, "--rounds")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("--rounds requires a value", .{});
            config.rounds = std.fmt.parseInt(usize, value, 10) catch
                return invalid("--rounds expects a positive integer", .{});
        } else if (std.mem.eql(u8, option.name, "--workers")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("--workers requires a value", .{});
            config.workers = std.fmt.parseInt(usize, value, 10) catch
                return invalid("--workers expects a non-negative integer", .{});
        } else if (std.mem.eql(u8, option.name, "--timeout")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("--timeout requires a value", .{});
            config.timeout_s = std.fmt.parseFloat(f64, value) catch
                return invalid("--timeout expects a number of seconds", .{});
        } else if (std.mem.eql(u8, option.name, "--describe")) {
            const value = optionValue(option, args, &i) orelse
                return invalid("--describe requires NAME=TEXT", .{});
            try config.describes.append(arena, value);
        } else if (std.mem.eql(u8, option.name, "--json")) {
            config.json_path = optionValue(option, args, &i) orelse
                return invalid("--json requires a path", .{});
        } else if (std.mem.eql(u8, option.name, "--markdown")) {
            config.markdown_path = optionValue(option, args, &i) orelse
                return invalid("--markdown requires a path", .{});
        } else if (std.mem.eql(u8, option.name, "--svg")) {
            config.svg_path = optionValue(option, args, &i) orelse
                return invalid("--svg requires a path", .{});
        } else if (std.mem.eql(u8, option.name, "--summary")) {
            config.summary_path = optionValue(option, args, &i) orelse
                return invalid("--summary requires a path", .{});
        } else if (std.mem.eql(u8, option.name, "--by-file")) {
            if (option.value != null) return invalid("--by-file takes no value", .{});
            config.by_file = true;
        } else if (std.mem.eql(u8, option.name, "--no-gitignore")) {
            if (option.value != null) return invalid("--no-gitignore takes no value", .{});
            config.no_gitignore = true;
        } else {
            return invalid("unrecognized option '{s}'", .{arg});
        }
    }

    if (config.rounds < 1) return invalid("--rounds must be at least 1", .{});
    if (config.timeout_s <= 0) return invalid("--timeout must be greater than zero", .{});
    if (config.repos.items.len == 0) return invalid("at least one --repo NAME=PATH is required", .{});

    for (config.repos.items) |entry| {
        if (!validPair(entry)) return invalid("--repo expects NAME=PATH, got '{s}'", .{entry});
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try seen.put(arena, "kazu", {});
    try seen.put(arena, "kazu-base", {});
    try seen.put(arena, "scc", {});
    try seen.put(arena, "tokei", {});
    try seen.put(arena, "mezura", {});
    for (config.kazu_variants.items) |entry| {
        if (!validPair(entry)) return invalid("--kazu-variant expects NAME=PATH, got '{s}'", .{entry});
        const eq = std.mem.indexOfScalar(u8, entry, '=').?;
        const name = entry[0..eq];
        if (!std.mem.startsWith(u8, name, "kazu")) {
            return invalid("--kazu-variant name must start with 'kazu', got '{s}'", .{name});
        }
        if (seen.contains(name)) {
            return invalid("--kazu-variant name '{s}' is reserved or repeated", .{name});
        }
        try seen.put(arena, name, {});
    }

    for (config.describes.items) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse
            return invalid("--describe expects NAME=TEXT, got '{s}'", .{entry});
        if (eq == 0) return invalid("--describe expects NAME=TEXT, got '{s}'", .{entry});
    }

    return config;
}

fn validPair(entry: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    return eq > 0 and eq + 1 < entry.len;
}

// ---------------------------------------------------------------------------
// Process execution
// ---------------------------------------------------------------------------

const RunOutcome = union(enum) {
    ok: Run,
    failed: []const u8,
};

const CaptureOutcome = union(enum) {
    ok: Counts,
    failed: []const u8,
};

/// Kills a child that overruns `--timeout`. The watchdog only acts while the
/// driver is still waiting, so a completed run is never signalled.
const Watchdog = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(self: *Watchdog, io: Io, child: *std.process.Child, timeout_s: f64) void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        const pid = child.id orelse return;
        const timeout_ns: i96 = @intFromFloat(timeout_s * @as(f64, @floatFromInt(std.time.ns_per_s)));
        const deadline = Io.Clock.Timestamp.fromNow(io, .{
            .raw = .{ .nanoseconds = timeout_ns },
            .clock = .awake,
        });
        self.thread = std.Thread.spawn(.{}, watch, .{
            io,
            pid,
            deadline,
            &self.done,
            &self.fired_flag,
        }) catch null;
    }

    fn stop(self: *Watchdog) void {
        self.done.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn fired(self: *const Watchdog) bool {
        return self.fired_flag.load(.acquire);
    }
};

fn watch(
    io: Io,
    pid: std.posix.pid_t,
    deadline: Io.Clock.Timestamp,
    done: *std.atomic.Value(bool),
    fired: *std.atomic.Value(bool),
) void {
    while (!done.load(.acquire)) {
        const now = Io.Clock.Timestamp.now(io, .awake);
        const remaining = deadline.raw.nanoseconds - now.raw.nanoseconds;
        if (remaining <= 0) {
            if (done.load(.acquire)) return;
            fired.store(true, .release);
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            return;
        }
        const slice: i96 = @min(remaining, watchdog_slice_ns);
        Io.sleep(io, .{ .nanoseconds = slice }, .awake) catch {};
    }
}

fn joinArgv(arena: Allocator, argv: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (argv, 0..) |arg, index| {
        if (index != 0) try aw.writer.writeByte(' ');
        try aw.writer.writeAll(arg);
    }
    return aw.written();
}

fn spawnFailure(arena: Allocator, err: anyerror, argv: []const []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), try joinArgv(arena, argv) });
}

const Usage = struct {
    cpu_ms: f64 = 0,
    maxrss_kb: u64 = 0,
};

fn usageOf(child: *const std.process.Child) Usage {
    var usage: Usage = .{};
    if (child.resource_usage_statistics.getMaxRss()) |bytes| {
        usage.maxrss_kb = bytes / 1024;
    }
    switch (builtin.os.tag) {
        .windows, .wasi => {},
        else => if (child.resource_usage_statistics.rusage) |ru| {
            const seconds: f64 = @floatFromInt(ru.utime.sec + ru.stime.sec);
            const micros: f64 = @floatFromInt(ru.utime.usec + ru.stime.usec);
            usage.cpu_ms = seconds * 1000.0 + micros / 1000.0;
        },
    }
    return usage;
}

fn termFailure(
    arena: Allocator,
    term: std.process.Child.Term,
    argv: []const []const u8,
    detail: ?[]const u8,
) !?[]const u8 {
    switch (term) {
        .exited => |code| {
            if (code == 0) return null;
            const command = try joinArgv(arena, argv);
            if (detail) |line| {
                return try std.fmt.allocPrint(
                    arena,
                    "exit code {d}: {s}: {s}",
                    .{ code, command, line },
                );
            }
            return try std.fmt.allocPrint(arena, "exit code {d}: {s}", .{ code, command });
        },
        .signal => |sig| return try std.fmt.allocPrint(
            arena,
            "killed by signal {d}: {s}",
            .{ @backingInt(sig), try joinArgv(arena, argv) },
        ),
        .stopped => |sig| return try std.fmt.allocPrint(
            arena,
            "stopped by signal {d}: {s}",
            .{ @backingInt(sig), try joinArgv(arena, argv) },
        ),
        .unknown => |status| return try std.fmt.allocPrint(
            arena,
            "terminated unexpectedly (status {d}): {s}",
            .{ status, try joinArgv(arena, argv) },
        ),
    }
}

fn timeoutFailure(arena: Allocator, timeout_s: f64, argv: []const []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "timed out after {d}s: {s}",
        .{ timeout_s, try joinArgv(arena, argv) },
    );
}

fn runTimed(
    arena: Allocator,
    io: Io,
    argv: []const []const u8,
    timeout_s: f64,
) !RunOutcome {
    const start = Io.Clock.awake.now(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = true,
    }) catch |err| return .{ .failed = try spawnFailure(arena, err, argv) };
    defer child.kill(io);

    var dog: Watchdog = .{};
    dog.start(io, &child, timeout_s);
    defer dog.stop();

    const term = child.wait(io) catch |err| {
        return .{ .failed = try spawnFailure(arena, err, argv) };
    };
    // Timestamp before joining the watchdog: the join can wait for its current
    // sleep slice, which must not be charged to the tool.
    const end = Io.Clock.awake.now(io);
    // Stop the watchdog before doing any work: once `wait` returns the pid has
    // been reaped, so a late signal could hit an unrelated process.
    dog.stop();

    if (dog.fired()) return .{ .failed = try timeoutFailure(arena, timeout_s, argv) };
    if (try termFailure(arena, term, argv, null)) |message| return .{ .failed = message };

    const usage = usageOf(&child);
    const wall_ns = end.nanoseconds - start.nanoseconds;
    return .{ .ok = .{
        .wall_ms = @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)),
        .cpu_ms = usage.cpu_ms,
        .maxrss_kb = usage.maxrss_kb,
    } };
}

/// Keeps the head of a tool's stderr so a failed capture run can report the
/// reason, matching what the pipeline shows in its logs. Only the first 8 KiB
/// are kept; that is plenty for a compiler-style diagnostic.
const stderr_limit: usize = 8 * 1024;

/// Reads a pipe until EOF, keeping the first `buffer.len` bytes. Safe to call
/// either on the driving thread or on a helper thread, so a run can drain
/// stdout and stderr at the same time.
const PipeDrain = struct {
    fn run(io: Io, file: std.Io.File, buffer: []u8, len: *std.atomic.Value(usize)) void {
        var total: usize = 0;
        var scratch: [4096]u8 = undefined;
        while (true) {
            // Keep reading past `buffer.len`: leaving the pipe unread would
            // block a chatty child once the pipe fills.
            const n = file.readStreaming(io, &.{scratch[0..]}) catch break;
            if (n == 0) break;
            if (total < buffer.len) {
                const take = @min(n, buffer.len - total);
                @memcpy(buffer[total..][0..take], scratch[0..take]);
                total += take;
            }
        }
        len.store(total, .release);
    }
};

fn lastLine(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const start = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse 0;
    const line = if (start == 0) trimmed else trimmed[start + 1 ..];
    const result = std.mem.trim(u8, line, " \t\r");
    return if (result.len == 0) null else result;
}

fn runCapture(
    arena: Allocator,
    io: Io,
    argv: []const []const u8,
    kind: ToolKind,
    timeout_s: f64,
) !CaptureOutcome {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .failed = try spawnFailure(arena, err, argv) };
    defer child.kill(io);

    var dog: Watchdog = .{};
    dog.start(io, &child, timeout_s);
    defer dog.stop();

    const stderr_buffer = try arena.alloc(u8, stderr_limit);
    var stderr_len = std.atomic.Value(usize).init(0);
    const stderr_thread = std.Thread.spawn(.{}, PipeDrain.run, .{
        io,
        child.stderr.?,
        stderr_buffer,
        &stderr_len,
    }) catch null;

    var counts: Counts = .{};
    var parse_err: ?anyerror = null;
    {
        var read_buffer: [read_buffer_size]u8 = undefined;
        var file_reader = child.stdout.?.readerStreaming(io, &read_buffer);
        var walker: Walker = .init(arena, &file_reader.interface);
        defer walker.deinit();
        counts = parseWith(kind, &walker) catch |err| blk: {
            parse_err = err;
            break :blk .{};
        };
        // A tool that is still writing must be able to finish, or it would
        // block on a full pipe while we wait for it below.
        _ = file_reader.interface.discardRemaining() catch 0;
    }
    // `wait` closes the pipe handles, so the drain thread has to be finished
    // first. It ends when the child closes stderr, which is normally exit.
    if (stderr_thread) |thread| thread.join();

    const term = child.wait(io) catch |err| {
        return .{ .failed = try spawnFailure(arena, err, argv) };
    };
    dog.stop();

    if (dog.fired()) return .{ .failed = try timeoutFailure(arena, timeout_s, argv) };
    const detail = lastLine(stderr_buffer[0..stderr_len.load(.acquire)]);
    if (try termFailure(arena, term, argv, detail)) |message| return .{ .failed = message };
    if (parse_err) |err| {
        return .{ .failed = try std.fmt.allocPrint(
            arena,
            "invalid {s} output ({s}): {s}",
            .{ @tagName(kind), @errorName(err), try joinArgv(arena, argv) },
        ) };
    }
    return .{ .ok = counts };
}

/// `--version` is capped so a hung binary cannot stall the run. Versions go to
/// stdout for most tools and to stderr for a few, so both pipes are drained and
/// stdout wins when it has content.
fn toolVersion(arena: Allocator, io: Io, exe: []const u8) []const u8 {
    const argv = [_][]const u8{ exe, "--version" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return "unknown";
    defer child.kill(io);

    var dog: Watchdog = .{};
    dog.start(io, &child, version_timeout_s);
    defer dog.stop();

    const stdout_buffer = arena.alloc(u8, 64 * 1024) catch return "unknown";
    const stderr_buffer = arena.alloc(u8, 64 * 1024) catch return "unknown";
    var stdout_len = std.atomic.Value(usize).init(0);
    var stderr_len = std.atomic.Value(usize).init(0);
    const stderr_thread = std.Thread.spawn(.{}, PipeDrain.run, .{
        io,
        child.stderr.?,
        stderr_buffer,
        &stderr_len,
    }) catch null;
    PipeDrain.run(io, child.stdout.?, stdout_buffer, &stdout_len);
    if (stderr_thread) |thread| thread.join();

    const term = child.wait(io) catch return "unknown";
    dog.stop();
    if (dog.fired() or !term.success()) return "unknown";

    const out = stdout_buffer[0..stdout_len.load(.acquire)];
    const err = stderr_buffer[0..stderr_len.load(.acquire)];
    const raw = if (out.len > 0) out else err;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return "unknown";
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r");
}

// ---------------------------------------------------------------------------
// Tool commands
// ---------------------------------------------------------------------------

fn isKazu(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "kazu");
}

fn buildCommand(
    arena: Allocator,
    tool: Tool,
    path: []const u8,
    config: Config,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    switch (tool.kind) {
        .kazu => {
            try argv.append(arena, tool.path);
            try argv.appendSlice(arena, &.{ "--format", "json" });
            if (config.workers > 0) {
                try argv.append(arena, "--workers");
                try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{config.workers}));
            }
            if (config.by_file) try argv.append(arena, "--by-file");
            if (config.no_gitignore) {
                try argv.appendSlice(arena, &.{ "--no-gitignore", "--no-ignore" });
            }
            try argv.append(arena, path);
        },
        .scc => {
            try argv.append(arena, tool.path);
            try argv.appendSlice(arena, &.{ "--no-complexity", "--no-cocomo", "--format", "json" });
            if (config.by_file) try argv.append(arena, "--by-file");
            if (config.no_gitignore) {
                // --no-gitignore only covers .gitignore; scc also reads .ignore
                // and .sccignore, which tokei's --no-ignore would disable.
                try argv.appendSlice(arena, &.{ "--no-gitignore", "--no-ignore", "--no-scc-ignore" });
            }
            try argv.append(arena, path);
        },
        .tokei => {
            // tokei's JSON output always carries per-file reports, so --files
            // changes only the terminal renderer; it is still the closest
            // per-file switch.
            try argv.append(arena, tool.path);
            try argv.appendSlice(arena, &.{ "--output", "json" });
            if (config.by_file) try argv.append(arena, "--files");
            if (config.no_gitignore) try argv.append(arena, "--no-ignore");
            try argv.append(arena, path);
        },
        .mezura => {
            // mezura defaults to a content-based model and drops minified,
            // generated, and non-code files while skipping dotted directories.
            // None of the other tools do that, so switch to the cloc/tokei/scc
            // region model and count those files. --no-default-config/--no-local
            // keep machine and project settings out, and --hide keywords/tests
            // drops the extra dimensions the other tools do not report.
            try argv.append(arena, tool.path);
            try argv.append(arena, path);
            try argv.appendSlice(arena, &.{
                "--output",            "json",
                "--counting",          "region",
                "--count-minified",    "--count-generated",
                "--count-not-code",    "--search-in-dotted",
                "--no-default-config", "--no-local",
                "--hide",              "keywords,tests",
            });
            if (config.by_file) try argv.append(arena, "--by-file");
            if (config.no_gitignore) {
                // mezura splits .gitignore from .ignore/.rgignore, so both
                // flags are needed to match the other tools' full disable.
                try argv.appendSlice(arena, &.{ "--no-gitignore", "--no-ignore-files" });
            }
        },
    }
    return argv.items;
}

// ---------------------------------------------------------------------------
// Streaming JSON tokenizer
// ---------------------------------------------------------------------------

const Token = union(enum) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    true,
    false,
    null,
    string: []const u8,
    number: []const u8,
    end_of_document,
};

/// Wraps `std.json.Scanner.Reader` and reassembles tokens that straddle a
/// read-buffer boundary, so the parsers never see a partial string or number.
const Tokens = struct {
    gpa: Allocator,
    scanner: std.json.Scanner.Reader,
    scratch: std.ArrayList(u8) = .empty,

    fn init(gpa: Allocator, reader: *Io.Reader) Tokens {
        return .{
            .gpa = gpa,
            .scanner = std.json.Scanner.Reader.init(gpa, reader),
        };
    }

    fn deinit(self: *Tokens) void {
        self.scanner.deinit();
        self.scratch.deinit(self.gpa);
    }

    fn next(self: *Tokens) !Token {
        self.scratch.clearRetainingCapacity();
        var partial = false;
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .object_begin => return .object_begin,
                .object_end => return .object_end,
                .array_begin => return .array_begin,
                .array_end => return .array_end,
                .true => return .true,
                .false => return .false,
                .null => return .null,
                .end_of_document => return .end_of_document,
                .number => |text| {
                    if (!partial) return .{ .number = text };
                    try self.scratch.appendSlice(self.gpa, text);
                    return .{ .number = self.scratch.items };
                },
                .string => |text| {
                    if (!partial) return .{ .string = text };
                    try self.scratch.appendSlice(self.gpa, text);
                    return .{ .string = self.scratch.items };
                },
                .partial_number => |text| {
                    partial = true;
                    try self.scratch.appendSlice(self.gpa, text);
                },
                .partial_string => |text| {
                    partial = true;
                    try self.scratch.appendSlice(self.gpa, text);
                },
                .partial_string_escaped_1 => |bytes| {
                    partial = true;
                    try self.scratch.appendSlice(self.gpa, bytes[0..]);
                },
                .partial_string_escaped_2 => |bytes| {
                    partial = true;
                    try self.scratch.appendSlice(self.gpa, bytes[0..]);
                },
                .partial_string_escaped_3 => |bytes| {
                    partial = true;
                    try self.scratch.appendSlice(self.gpa, bytes[0..]);
                },
                .partial_string_escaped_4 => |bytes| {
                    partial = true;
                    try self.scratch.appendSlice(self.gpa, bytes[0..]);
                },
                .allocated_number, .allocated_string => unreachable,
            }
        }
    }
};

const Container = enum { object, array };

const Kind = enum {
    begin_object,
    end_object,
    begin_array,
    end_array,
    key,
    string,
    number,
    boolean,
    null,
    end_of_document,
};

const TokenInfo = struct {
    kind: Kind,
    text: []const u8 = "",
    /// Container depth after this token: the new depth for a begin token, the
    /// parent depth for an end token, and the containing depth for a value.
    depth: usize = 0,
};

/// Tracks object/array nesting so each parser can key off depth alone.
const Walker = struct {
    tokens: Tokens,
    stack: [max_json_depth]Container = undefined,
    len: usize = 0,
    key_pending: bool = false,

    fn init(gpa: Allocator, reader: *Io.Reader) Walker {
        return .{ .tokens = Tokens.init(gpa, reader) };
    }

    fn deinit(self: *Walker) void {
        self.tokens.deinit();
    }

    fn next(self: *Walker) !TokenInfo {
        const token = try self.tokens.next();
        switch (token) {
            .object_begin => {
                if (self.len == self.stack.len) return error.NestingTooDeep;
                self.stack[self.len] = .object;
                self.len += 1;
                self.key_pending = true;
                return .{ .kind = .begin_object, .depth = self.len };
            },
            .object_end => {
                if (self.len == 0) return error.UnbalancedJson;
                self.len -= 1;
                self.key_pending = self.len > 0 and self.stack[self.len - 1] == .object;
                return .{ .kind = .end_object, .depth = self.len };
            },
            .array_begin => {
                if (self.len == self.stack.len) return error.NestingTooDeep;
                self.stack[self.len] = .array;
                self.len += 1;
                self.key_pending = false;
                return .{ .kind = .begin_array, .depth = self.len };
            },
            .array_end => {
                if (self.len == 0) return error.UnbalancedJson;
                self.len -= 1;
                self.key_pending = self.len > 0 and self.stack[self.len - 1] == .object;
                return .{ .kind = .end_array, .depth = self.len };
            },
            .string => |text| {
                if (self.key_pending) {
                    self.key_pending = false;
                    return .{ .kind = .key, .text = text, .depth = self.len };
                }
                self.finishValue();
                return .{ .kind = .string, .text = text, .depth = self.len };
            },
            .number => |text| {
                self.finishValue();
                return .{ .kind = .number, .text = text, .depth = self.len };
            },
            .true, .false => {
                self.finishValue();
                return .{ .kind = .boolean, .depth = self.len };
            },
            .null => {
                self.finishValue();
                return .{ .kind = .null, .depth = self.len };
            },
            .end_of_document => return .{ .kind = .end_of_document },
        }
    }

    fn finishValue(self: *Walker) void {
        if (self.len > 0 and self.stack[self.len - 1] == .object) self.key_pending = true;
    }
};

// ---------------------------------------------------------------------------
// Output parsers
// ---------------------------------------------------------------------------

const Field = enum {
    unknown,
    name,
    files,
    lines,
    code,
    comments,
    blanks,
    extra,
    count,
    reports,
};

fn classify(text: []const u8) Field {
    if (std.mem.eql(u8, text, "Files") or std.mem.eql(u8, text, "files")) return .files;
    if (std.mem.eql(u8, text, "Lines") or std.mem.eql(u8, text, "lines")) return .lines;
    if (std.mem.eql(u8, text, "Code") or std.mem.eql(u8, text, "code")) return .code;
    if (std.mem.eql(u8, text, "Comment") or std.mem.eql(u8, text, "comments")) return .comments;
    if (std.mem.eql(u8, text, "Blank") or std.mem.eql(u8, text, "blanks")) return .blanks;
    if (std.mem.eql(u8, text, "Extra") or std.mem.eql(u8, text, "extra")) return .extra;
    if (std.mem.eql(u8, text, "Count")) return .count;
    if (std.mem.eql(u8, text, "Name")) return .name;
    if (std.mem.eql(u8, text, "reports")) return .reports;
    return .unknown;
}

fn addCounts(target: *Counts, source: Counts) void {
    target.files += source.files;
    target.lines += source.lines;
    target.code += source.code;
    target.comments += source.comments;
    target.blanks += source.blanks;
}

fn addField(row: *Counts, field: Field, value: u64) void {
    switch (field) {
        .files, .count => row.files += value,
        .lines => row.lines += value,
        .code => row.code += value,
        .comments => row.comments += value,
        .blanks => row.blanks += value,
        else => {},
    }
}

fn parseWith(kind: ToolKind, walker: *Walker) !Counts {
    return switch (kind) {
        .kazu => parseRows(walker, false),
        .scc => parseRows(walker, true),
        .tokei => parseTokei(walker),
        .mezura => parseMezura(walker),
    };
}

/// kazu and scc emit an array of per-language rows. scc also nests per-file
/// reports under a `Files` array and appends a `Total` row, so only depth-two
/// objects contribute and the Total row is skipped.
fn parseRows(walker: *Walker, skip_total: bool) !Counts {
    var counts: Counts = .{};
    var row: Counts = .{};
    var row_is_total = false;
    var in_row = false;
    var field: Field = .unknown;

    while (true) {
        const info = try walker.next();
        switch (info.kind) {
            .end_of_document => break,
            .begin_object => if (info.depth == 2) {
                in_row = true;
                row = .{};
                row_is_total = false;
                field = .unknown;
            },
            .end_object => if (in_row and info.depth == 1) {
                in_row = false;
                if (!(skip_total and row_is_total)) addCounts(&counts, row);
            },
            .key => {
                if (info.depth == 2) field = classify(info.text);
            },
            .string => if (info.depth == 2 and skip_total and field == .name) {
                if (std.mem.eql(u8, info.text, "Total")) row_is_total = true;
            },
            .number => if (info.depth == 2) {
                const value = std.fmt.parseInt(u64, info.text, 10) catch 0;
                addField(&row, field, value);
            },
            else => {},
        }
    }
    return counts;
}

/// tokei emits an object keyed by language. Totals come from `Total`; files are
/// the number of entries in each language's `reports` array. Nested `children`
/// reports repeat the same files and are ignored.
fn parseTokei(walker: *Walker) !Counts {
    var total_code: u64 = 0;
    var total_comments: u64 = 0;
    var total_blanks: u64 = 0;
    var sum_code: u64 = 0;
    var sum_comments: u64 = 0;
    var sum_blanks: u64 = 0;
    var report_files: u64 = 0;
    var saw_total = false;
    var language_is_total = false;
    var field: Field = .unknown;
    var pending_reports = false;
    var in_reports = false;
    var reports_depth: usize = 0;

    while (true) {
        const info = try walker.next();
        switch (info.kind) {
            .end_of_document => break,
            .key => if (info.depth == 1) {
                language_is_total = std.mem.eql(u8, info.text, "Total");
            } else if (info.depth == 2) {
                field = classify(info.text);
                pending_reports = field == .reports;
            },
            .begin_object => {
                if (info.depth == 2) {
                    if (language_is_total) saw_total = true;
                } else if (in_reports and info.depth == reports_depth + 1) {
                    if (!language_is_total) report_files += 1;
                }
            },
            .begin_array => if (pending_reports and info.depth == 3) {
                in_reports = true;
                reports_depth = 3;
                pending_reports = false;
            },
            .end_array => if (in_reports and info.depth == 2) {
                in_reports = false;
            },
            .number => if (info.depth == 2) {
                const value = std.fmt.parseInt(u64, info.text, 10) catch 0;
                switch (field) {
                    .code => if (language_is_total) {
                        total_code += value;
                    } else {
                        sum_code += value;
                    },
                    .comments => if (language_is_total) {
                        total_comments += value;
                    } else {
                        sum_comments += value;
                    },
                    .blanks => if (language_is_total) {
                        total_blanks += value;
                    } else {
                        sum_blanks += value;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    var counts: Counts = .{ .files = report_files };
    if (saw_total) {
        counts.code = total_code;
        counts.comments = total_comments;
        counts.blanks = total_blanks;
    } else {
        counts.code = sum_code;
        counts.comments = sum_comments;
        counts.blanks = sum_blanks;
    }
    counts.lines = counts.code + counts.comments + counts.blanks;
    return counts;
}

/// mezura reports a top-level `total` object. The region model calls the third
/// column `blanks`; the content model calls it `extra`.
fn parseMezura(walker: *Walker) !Counts {
    var counts: Counts = .{};
    var pending_total = false;
    var in_total = false;
    var has_blanks = false;
    var extra: u64 = 0;
    var field: Field = .unknown;

    while (true) {
        const info = try walker.next();
        switch (info.kind) {
            .end_of_document => break,
            .key => if (info.depth == 1) {
                pending_total = std.mem.eql(u8, info.text, "total");
            } else if (info.depth == 2 and in_total) {
                field = classify(info.text);
            },
            .begin_object => if (info.depth == 2 and pending_total) {
                in_total = true;
                pending_total = false;
            },
            .end_object => if (in_total and info.depth == 1) {
                in_total = false;
            },
            .number => if (in_total and info.depth == 2) {
                const value = std.fmt.parseInt(u64, info.text, 10) catch 0;
                switch (field) {
                    .files => counts.files = value,
                    .lines => counts.lines = value,
                    .code => counts.code = value,
                    .comments => counts.comments = value,
                    .blanks => {
                        counts.blanks = value;
                        has_blanks = true;
                    },
                    .extra => extra = value,
                    else => {},
                }
            },
            else => {},
        }
    }
    if (!has_blanks) counts.blanks = extra;
    return counts;
}

// ---------------------------------------------------------------------------
// Statistics and formatting
// ---------------------------------------------------------------------------

fn describe(values: []f64) Stats {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const n = values.len;
    const median = if (n % 2 == 1)
        values[n / 2]
    else
        (values[n / 2 - 1] + values[n / 2]) / 2.0;

    // Neumaier summation, close to Python's fsum for the handful of samples
    // collected per tool.
    var sum: f64 = 0;
    var compensation: f64 = 0;
    for (values) |value| {
        const next = sum + value;
        compensation += if (@abs(sum) >= @abs(value))
            (sum - next) + value
        else
            (value - next) + sum;
        sum = next;
    }
    const count: f64 = @floatFromInt(n);
    const mean = (sum + compensation) / count;

    var squares: f64 = 0;
    for (values) |value| {
        const delta = value - mean;
        squares += delta * delta;
    }
    const stdev = if (n > 1)
        @sqrt(squares / @as(f64, @floatFromInt(n - 1)))
    else
        0.0;

    return .{
        .n = n,
        .median = median,
        .mean = mean,
        .stdev = stdev,
        .min = values[0],
        .max = values[n - 1],
    };
}

fn summarize(
    arena: Allocator,
    runs: []const Run,
    counts: ?Counts,
    err: ?[]const u8,
) !Summary {
    if (err != null or runs.len == 0) {
        return .{ .err = err orelse "no runs", .counts = counts };
    }

    const wall = try arena.alloc(f64, runs.len);
    const cpu = try arena.alloc(f64, runs.len);
    const rss = try arena.alloc(f64, runs.len);
    for (runs, 0..) |run, index| {
        wall[index] = run.wall_ms;
        cpu[index] = run.cpu_ms;
        rss[index] = @floatFromInt(run.maxrss_kb);
    }

    return .{
        .wall = describe(wall),
        .cpu = describe(cpu),
        .rss = describe(rss),
        .counts = counts,
    };
}

fn writeDuration(w: *Io.Writer, ms: f64) !void {
    if (ms >= 1000.0) {
        try w.print("{d:.2} s", .{ms / 1000.0});
    } else if (ms >= 100.0) {
        try w.print("{d:.0} ms", .{ms});
    } else {
        try w.print("{d:.1} ms", .{ms});
    }
}

fn writeRatio(w: *Io.Writer, value: f64) !void {
    try w.print("{d:.2}x", .{value});
}

fn writeRss(w: *Io.Writer, kb: f64) !void {
    const mib = kb / 1024.0;
    if (mib >= 1024.0) {
        try w.print("{d:.2} GiB", .{mib / 1024.0});
    } else {
        try w.print("{d:.1} MiB", .{mib});
    }
}

fn rssString(buffer: []u8, kb: f64) []const u8 {
    const mib = kb / 1024.0;
    if (mib >= 1024.0) {
        return std.fmt.bufPrint(buffer, "{d:.2} GiB", .{mib / 1024.0}) catch "?";
    }
    return std.fmt.bufPrint(buffer, "{d:.1} MiB", .{mib}) catch "?";
}

fn writeCount(w: *Io.Writer, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    for (text, 0..) |digit, index| {
        if (index != 0 and (text.len - index) % 3 == 0) try w.writeByte(',');
        try w.writeByte(digit);
    }
}

fn countString(buffer: []u8, value: u64) []const u8 {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "?";
    var out: usize = 0;
    for (text, 0..) |digit, index| {
        if (index != 0 and (text.len - index) % 3 == 0) {
            buffer[out] = ',';
            out += 1;
        }
        buffer[out] = digit;
        out += 1;
    }
    return buffer[0..out];
}

fn roundHalfEven(value: f64) f64 {
    const floor = @floor(value);
    const fraction = value - floor;
    if (fraction > 0.5) return floor + 1.0;
    if (fraction < 0.5) return floor;
    return if (@mod(floor, 2.0) == 0.0) floor else floor + 1.0;
}

fn rssBar(value: f64, maximum: f64, width: usize) usize {
    if (maximum <= 0 or value <= 0) return 0;
    const scaled = value / maximum * @as(f64, @floatFromInt(width));
    const blocks: f64 = roundHalfEven(scaled);
    return @max(1, @as(usize, @intFromFloat(blocks)));
}

// ---------------------------------------------------------------------------
// JSON report
// ---------------------------------------------------------------------------

fn writeIndent(w: *Io.Writer, spaces: usize) !void {
    for (0..spaces) |_| try w.writeByte(' ');
}

fn writeJsonString(w: *Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        else => if (byte < 0x20) {
            try w.print("\\u{x:0>4}", .{byte});
        } else {
            try w.writeByte(byte);
        },
    };
    try w.writeByte('"');
}

/// Python's `repr` for the magnitudes this report contains: shortest
/// round-trip digits, with `.0` kept on integral values.
fn writeJsonFloat(w: *Io.Writer, value: f64) !void {
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch {
        try w.writeAll("0.0");
        return;
    };
    try w.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try w.writeAll(".0");
}

fn writeStatsJson(w: *Io.Writer, name: []const u8, stats: Stats, indent: usize) !void {
    try writeIndent(w, indent);
    try writeJsonString(w, name);
    try w.writeAll(": {\n");
    try writeIndent(w, indent + 2);
    try w.print("\"n\": {d},\n", .{stats.n});
    try writeIndent(w, indent + 2);
    try w.writeAll("\"median\": ");
    try writeJsonFloat(w, stats.median);
    try w.writeAll(",\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("\"mean\": ");
    try writeJsonFloat(w, stats.mean);
    try w.writeAll(",\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("\"stdev\": ");
    try writeJsonFloat(w, stats.stdev);
    try w.writeAll(",\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("\"min\": ");
    try writeJsonFloat(w, stats.min);
    try w.writeAll(",\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("\"max\": ");
    try writeJsonFloat(w, stats.max);
    try w.writeAll("\n");
    try writeIndent(w, indent);
    try w.writeAll("}");
}

fn writeCountsJson(w: *Io.Writer, counts: ?Counts, indent: usize) !void {
    const value = counts orelse {
        try w.writeAll("null");
        return;
    };
    try w.writeAll("{\n");
    try writeIndent(w, indent + 2);
    try w.print("\"files\": {d},\n", .{value.files});
    try writeIndent(w, indent + 2);
    try w.print("\"lines\": {d},\n", .{value.lines});
    try writeIndent(w, indent + 2);
    try w.print("\"code\": {d},\n", .{value.code});
    try writeIndent(w, indent + 2);
    try w.print("\"comments\": {d},\n", .{value.comments});
    try writeIndent(w, indent + 2);
    try w.print("\"blanks\": {d}\n", .{value.blanks});
    try writeIndent(w, indent);
    try w.writeAll("}");
}

fn renderJson(arena: Allocator, report: *const Report) ![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(arena);
    const w = &allocating.writer;
    const tools = report.tools;

    try w.writeAll("{\n");
    try writeIndent(w, 2);
    try w.writeAll("\"generated_at\": ");
    try writeJsonString(w, report.generated_at);
    try w.writeAll(",\n");
    try writeIndent(w, 2);
    try w.print("\"rounds\": {d},\n", .{report.rounds});
    try writeIndent(w, 2);
    try w.print("\"workers\": {d},\n", .{report.workers});
    try writeIndent(w, 2);
    try w.print("\"by_file\": {s},\n", .{if (report.options.by_file) "true" else "false"});
    try writeIndent(w, 2);
    try w.print("\"no_gitignore\": {s},\n", .{if (report.options.no_gitignore) "true" else "false"});

    try writeIndent(w, 2);
    try w.writeAll("\"versions\": {\n");
    for (tools, 0..) |tool, index| {
        try writeIndent(w, 4);
        try writeJsonString(w, tool.name);
        try w.writeAll(": ");
        try writeJsonString(w, tool.version);
        try w.writeAll(if (index + 1 < tools.len) ",\n" else "\n");
    }
    try writeIndent(w, 2);
    try w.writeAll("},\n");

    try writeIndent(w, 2);
    try w.writeAll("\"tools\": [\n");
    for (tools, 0..) |tool, index| {
        try writeIndent(w, 4);
        try writeJsonString(w, tool.name);
        try w.writeAll(if (index + 1 < tools.len) ",\n" else "\n");
    }
    try writeIndent(w, 2);
    try w.writeAll("],\n");

    try writeIndent(w, 2);
    try w.writeAll("\"repos\": [\n");
    for (report.repos, 0..) |repo, repo_index| {
        try writeIndent(w, 4);
        try w.writeAll("{\n");
        try writeIndent(w, 6);
        try w.writeAll("\"repo\": ");
        try writeJsonString(w, repo.label);
        try w.writeAll(",\n");
        try writeIndent(w, 6);
        try w.writeAll("\"path\": ");
        try writeJsonString(w, repo.path);
        try w.writeAll(",\n");

        if (repo.err) |message| {
            try writeIndent(w, 6);
            try w.writeAll("\"tools\": {},\n");
            try writeIndent(w, 6);
            try w.writeAll("\"error\": ");
            try writeJsonString(w, message);
            try w.writeAll("\n");
        } else {
            try writeIndent(w, 6);
            try w.writeAll("\"tools\": {\n");
            for (tools, 0..) |tool, tool_index| {
                const summary = repo.summaries[tool_index];
                try writeIndent(w, 8);
                try writeJsonString(w, tool.name);
                try w.writeAll(": {\n");
                if (summary.err) |message| {
                    try writeIndent(w, 10);
                    try w.writeAll("\"error\": ");
                    try writeJsonString(w, message);
                    try w.writeAll(",\n");
                    try writeIndent(w, 10);
                    try w.writeAll("\"counts\": ");
                    try writeCountsJson(w, summary.counts, 10);
                    try w.writeAll("\n");
                } else {
                    try writeStatsJson(w, "wall_ms", summary.wall.?, 10);
                    try w.writeAll(",\n");
                    try writeStatsJson(w, "cpu_ms", summary.cpu.?, 10);
                    try w.writeAll(",\n");
                    try writeStatsJson(w, "maxrss_kb", summary.rss.?, 10);
                    try w.writeAll(",\n");
                    try writeIndent(w, 10);
                    try w.writeAll("\"counts\": ");
                    try writeCountsJson(w, summary.counts, 10);
                    try w.writeAll("\n");
                }
                try writeIndent(w, 8);
                try w.writeAll("}");
                try w.writeAll(if (tool_index + 1 < tools.len) ",\n" else "\n");
            }
            try writeIndent(w, 6);
            try w.writeAll("}\n");
        }

        try writeIndent(w, 4);
        try w.writeAll("}");
        try w.writeAll(if (repo_index + 1 < report.repos.len) ",\n" else "\n");
    }
    try writeIndent(w, 2);
    try w.writeAll("]\n");
    try w.writeAll("}\n");
    return allocating.written();
}

// ---------------------------------------------------------------------------
// Markdown report
// ---------------------------------------------------------------------------

fn kazuBaseline(tools: []const Tool) ?usize {
    for (tools, 0..) |tool, index| {
        if (isKazu(tool.name)) return index;
    }
    return null;
}

fn ignoreFlags(name: []const u8) ?[]const u8 {
    if (isKazu(name)) return "`--no-gitignore --no-ignore`";
    if (std.mem.eql(u8, name, "scc")) return "`--no-gitignore --no-ignore --no-scc-ignore`";
    if (std.mem.eql(u8, name, "tokei")) return "`--no-ignore`";
    if (std.mem.eql(u8, name, "mezura")) return "`--no-gitignore --no-ignore-files`";
    return null;
}

fn writeIgnoreLabel(w: *Io.Writer, tools: []const Tool, no_gitignore: bool) !void {
    if (!no_gitignore) {
        try w.writeAll("honored by every tool (no `--no-gitignore`)");
        return;
    }
    try w.writeAll("disabled by every tool (");
    var first = true;
    for (tools) |tool| {
        const flags = ignoreFlags(tool.name) orelse continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{s} {s}", .{ tool.name, flags });
    }
    try w.writeAll(")");
}

fn writeByFileLabel(
    w: *Io.Writer,
    arena: Allocator,
    tools: []const Tool,
    by_file: bool,
) !void {
    if (!by_file) {
        try w.writeAll("off (per-language totals)");
        return;
    }

    var label: std.Io.Writer.Allocating = .init(arena);
    const label_writer = &label.writer;
    var group_first = true;
    var any_group = false;
    for (tools) |tool| {
        const in_group = isKazu(tool.name) or
            std.mem.eql(u8, tool.name, "scc") or
            std.mem.eql(u8, tool.name, "mezura");
        if (!in_group) continue;
        if (!group_first) try label_writer.writeByte('/');
        group_first = false;
        any_group = true;
        try label_writer.writeAll(tool.name);
    }
    if (any_group) try label_writer.writeAll(" `--by-file`");

    var any = any_group;
    for (tools) |tool| {
        if (!std.mem.eql(u8, tool.name, "tokei")) continue;
        if (any) try label_writer.writeAll(", ");
        try label_writer.writeAll("tokei `--files`");
        any = true;
    }

    if (!any) {
        try w.writeAll("off (per-language totals)");
        return;
    }
    try w.writeAll("on (");
    try w.writeAll(label.written());
    try w.writeAll(")");
}

fn renderMarkdown(arena: Allocator, report: *const Report, svg_name: ?[]const u8) ![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(arena);
    const w = &allocating.writer;
    const tools = report.tools;
    const baseline = kazuBaseline(tools);

    try w.writeAll("# ");
    if (tools.len > 0) {
        for (tools, 0..) |tool, index| {
            if (index != 0) try w.writeAll(" vs ");
            try w.writeAll(tool.name);
        }
    } else {
        try w.writeAll("benchmark");
    }
    try w.writeAll("\n\n");
    try w.writeAll("- **Generated:** ");
    try w.writeAll(report.generated_at);
    try w.writeAll("\n");
    try w.print("- **Rounds:** {d} (interleaved; run order alternates each round)\n", .{report.rounds});
    try w.writeAll("- **kazu workers:** ");
    if (report.workers == 0) {
        try w.writeAll("default (CPU count)");
    } else {
        try w.print("{d}", .{report.workers});
    }
    try w.writeAll("\n- **Ignore files:** ");
    try writeIgnoreLabel(w, tools, report.options.no_gitignore);
    try w.writeAll("\n- **Per-file output:** ");
    try writeByFileLabel(w, arena, tools, report.options.by_file);
    try w.writeAll("\n");
    if (svg_name) |name| {
        try w.writeAll("- **Memory chart:** `");
        try w.writeAll(name);
        try w.writeAll("`\n");
    }

    for (tools) |tool| {
        try w.writeAll("- **");
        try w.writeAll(tool.name);
        try w.writeAll(":** `");
        try w.writeAll(tool.version);
        try w.writeAll("`");
        if (tool.description) |description| {
            try w.writeAll(" — ");
            try w.writeAll(description);
        }
        try w.writeAll("\n");
    }

    var usable: usize = 0;
    for (report.repos) |repo| {
        if (repo.err == null) usable += 1;
    }

    if (usable > 0) {
        try w.writeAll("\n## Summary\n\n");
        try w.writeAll("| Repository |");
        for (tools) |tool| try w.print(" {s} |", .{tool.name});
        if (baseline) |base| {
            for (tools, 0..) |tool, index| {
                if (index == base) continue;
                try w.print(" {s}/{s} |", .{ tools[base].name, tool.name });
            }
        }
        try w.writeAll("\n| --- |");
        for (tools) |_| try w.writeAll(" ---: |");
        if (baseline) |base| {
            for (tools, 0..) |_, index| {
                if (index == base) continue;
                try w.writeAll(" ---: |");
            }
        }
        try w.writeAll("\n");

        for (report.repos) |repo| {
            if (repo.err != null) continue;
            try w.writeAll("| ");
            try w.writeAll(repo.label);
            try w.writeAll(" |");

            var medians: [64]?f64 = @splat(null);
            for (tools, 0..) |_, index| {
                if (repo.summaries[index].wall) |wall| {
                    medians[index] = wall.median;
                    try w.writeAll(" ");
                    try writeDuration(w, wall.median);
                    try w.writeAll(" |");
                } else {
                    try w.writeAll(" — |");
                }
            }
            if (baseline) |base| {
                for (tools, 0..) |_, index| {
                    if (index == base) continue;
                    if (medians[index]) |value| {
                        if (medians[base]) |base_value| {
                            if (value > 0) {
                                try w.writeAll(" ");
                                try writeRatio(w, base_value / value);
                                try w.writeAll(" |");
                                continue;
                            }
                        }
                    }
                    try w.writeAll(" — |");
                }
            }
            try w.writeAll("\n");
        }

        var any_memory = false;
        for (report.repos) |repo| {
            if (repo.err != null) continue;
            for (repo.summaries) |summary| {
                if (summary.rss) |rss| {
                    if (rss.median != 0) any_memory = true;
                }
            }
        }
        if (any_memory) {
            try w.writeAll("\n### Peak memory\n\nMedian peak RSS (lower is better):\n\n");
            try w.writeAll("| Repository |");
            for (tools) |tool| try w.print(" {s} |", .{tool.name});
            try w.writeAll("\n| --- |");
            for (tools) |_| try w.writeAll(" ---: |");
            try w.writeAll("\n");
            for (report.repos) |repo| {
                if (repo.err != null) continue;
                try w.writeAll("| ");
                try w.writeAll(repo.label);
                try w.writeAll(" |");
                for (repo.summaries) |summary| {
                    if (summary.rss) |rss| {
                        if (rss.median != 0) {
                            try w.writeAll(" ");
                            try writeRss(w, rss.median);
                            try w.writeAll(" |");
                            continue;
                        }
                    }
                    try w.writeAll(" — |");
                }
                try w.writeAll("\n");
            }
        }
    }

    for (report.repos) |repo| {
        try w.writeAll("\n## ");
        try w.writeAll(repo.label);
        try w.writeAll("\n\n");
        if (repo.err) |message| {
            try w.writeAll("> **Failed:** ");
            try w.writeAll(message);
            try w.writeAll("\n");
            continue;
        }

        const ratio_header = if (baseline != null) "kazu/tool" else "ratio";
        try w.print("Timing (median of {d} rounds; ", .{report.rounds});
        if (baseline != null) {
            try w.print("`{s}` below 1.00x means the baseline kazu build was faster", .{ratio_header});
        } else {
            try w.writeAll("no kazu baseline to compare against");
        }
        try w.writeAll("):\n\n");
        try w.print("| Tool | Median | Mean | σ | Min | Max | CPU (median) | Peak RSS | {s} |\n", .{ratio_header});
        try w.writeAll("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n");

        const base_median: ?f64 = if (baseline) |base|
            if (repo.summaries[base].wall) |wall| wall.median else null
        else
            null;

        for (tools, 0..) |tool, index| {
            const summary = repo.summaries[index];
            if (summary.wall == null) {
                try w.print("| {s} | — | — | — | — | — | — | — | — |\n", .{tool.name});
                continue;
            }
            const wall = summary.wall.?;
            try w.print("| {s} | ", .{tool.name});
            try writeDuration(w, wall.median);
            try w.writeAll(" | ");
            try writeDuration(w, wall.mean);
            try w.writeAll(" | ");
            try writeDuration(w, wall.stdev);
            try w.writeAll(" | ");
            try writeDuration(w, wall.min);
            try w.writeAll(" | ");
            try writeDuration(w, wall.max);
            try w.writeAll(" | ");
            try writeDuration(w, summary.cpu.?.median);
            try w.writeAll(" | ");
            try writeRss(w, summary.rss.?.median);
            try w.writeAll(" | ");
            if (baseline == null) {
                try w.writeAll("—");
            } else if (index == baseline.?) {
                try w.writeAll("1.00x");
            } else if (base_median) |base_value| {
                if (wall.median > 0) {
                    try writeRatio(w, base_value / wall.median);
                } else {
                    try w.writeAll("—");
                }
            } else {
                try w.writeAll("—");
            }
            try w.writeAll(" |\n");
        }

        var memory_count: usize = 0;
        var memory_max: f64 = 0;
        var name_width: usize = 0;
        for (tools, 0..) |tool, index| {
            const summary = repo.summaries[index];
            if (summary.rss) |rss| {
                if (rss.median != 0) {
                    memory_count += 1;
                    memory_max = @max(memory_max, rss.median);
                    name_width = @max(name_width, tool.name.len);
                }
            }
        }
        if (memory_count > 0) {
            try w.writeAll("\nPeak memory (median peak RSS):\n\n```text\n");
            for (tools, 0..) |tool, index| {
                const summary = repo.summaries[index];
                const rss = summary.rss orelse continue;
                if (rss.median == 0) continue;
                try w.writeAll(tool.name);
                for (0..name_width - tool.name.len) |_| try w.writeByte(' ');
                try w.writeAll("  ");
                const blocks = rssBar(rss.median, memory_max, 24);
                for (0..blocks) |_| try w.writeAll("█");
                for (0..24 - blocks) |_| try w.writeByte(' ');
                try w.writeAll("  ");
                try writeRss(w, rss.median);
                try w.writeAll("\n");
            }
            try w.writeAll("```\n");
        }

        try w.writeAll("\nReported totals:\n\n");
        try w.writeAll("| Tool | Files | Lines | Code | Comments | Blank |\n");
        try w.writeAll("| --- | ---: | ---: | ---: | ---: | ---: |\n");
        for (tools, 0..) |tool, index| {
            const summary = repo.summaries[index];
            const counts = summary.counts orelse {
                try w.print("| {s} | — | — | — | — | — |\n", .{tool.name});
                continue;
            };
            try w.print("| {s} | ", .{tool.name});
            try writeCount(w, counts.files);
            try w.writeAll(" | ");
            try writeCount(w, counts.lines);
            try w.writeAll(" | ");
            try writeCount(w, counts.code);
            try w.writeAll(" | ");
            try writeCount(w, counts.comments);
            try w.writeAll(" | ");
            try writeCount(w, counts.blanks);
            try w.writeAll(" |\n");
        }
    }

    try w.writeAll("\n> Totals differ where the tools classify languages or lines differently;\n");
    try w.writeAll("> the timing table is the benchmark, the totals are a sanity check.\n");
    return allocating.written();
}

// ---------------------------------------------------------------------------
// Peak memory chart
// ---------------------------------------------------------------------------

const tool_colors = [_]struct { name: []const u8, color: []const u8 }{
    .{ .name = "kazu", .color = "#2f81f7" },
    .{ .name = "kazu-base", .color = "#d29922" },
    .{ .name = "scc", .color = "#f0883e" },
    .{ .name = "tokei", .color = "#3fb950" },
    .{ .name = "mezura", .color = "#a371f7" },
};

/// Extra kazu builds (one per requested ref) cycle through these so every bar
/// in the memory chart stays distinguishable.
const variant_colors = [_][]const u8{
    "#8250df", "#db61a2", "#1f6feb", "#9a6700", "#0a7ea4", "#bf8700",
};

fn toolColor(tools: []const Tool, index: usize) []const u8 {
    const name = tools[index].name;
    for (tool_colors) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.color;
    }
    var variant: usize = 0;
    for (tools[0..index]) |tool| {
        var known = false;
        for (tool_colors) |entry| {
            if (std.mem.eql(u8, entry.name, tool.name)) known = true;
        }
        if (!known) variant += 1;
    }
    return variant_colors[variant % variant_colors.len];
}

fn svgEscape(w: *Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(byte),
    };
}

const SvgValue = struct {
    tool: usize,
    value: f64,
};

const SvgGroup = struct {
    label: []const u8,
    values: []SvgValue,
};

fn renderSvg(arena: Allocator, report: *const Report) ![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(arena);
    const w = &allocating.writer;
    const tools = report.tools;

    var groups: std.ArrayList(SvgGroup) = .empty;
    for (report.repos) |repo| {
        if (repo.err != null) continue;
        var values: std.ArrayList(SvgValue) = .empty;
        for (tools, 0..) |_, index| {
            const summary = repo.summaries[index];
            if (summary.rss) |rss| {
                if (rss.median == 0) continue;
                try values.append(arena, .{ .tool = index, .value = rss.median });
            }
        }
        if (values.items.len > 0) {
            try groups.append(arena, .{ .label = repo.label, .values = values.items });
        }
    }

    const width: usize = 900;
    const left: usize = 200;
    const right: usize = 120;
    const top: usize = 76;
    const bottom: usize = 44;
    const bar_height: usize = 20;
    const bar_gap: usize = 6;
    const group_gap: usize = 20;
    const plot_width: usize = width - left - right;

    var body_height: usize = 0;
    for (groups.items) |group| {
        body_height += group.values.len * (bar_height + bar_gap) - bar_gap + group_gap;
    }
    const height = top + bottom + (if (groups.items.len > 0) body_height else 0);

    var maximum: f64 = 0;
    for (groups.items) |group| {
        for (group.values) |value| maximum = @max(maximum, value.value);
    }
    const scale_max = if (maximum > 0) maximum else 1.0;

    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" " ++
            "viewBox=\"0 0 {d} {d}\" role=\"img\" " ++
            "font-family=\"-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif\">\n",
        .{ width, height, width, height },
    );
    try w.print("<rect width=\"{d}\" height=\"{d}\" fill=\"#ffffff\"/>\n", .{ width, height });
    try w.print(
        "<text x=\"{d}\" y=\"30\" font-size=\"18\" font-weight=\"600\" fill=\"#1f2328\">" ++
            "Peak memory (median peak RSS)</text>\n",
        .{left},
    );

    var legend_width: usize = 0;
    for (tools) |tool| legend_width += 12 + 6 + tool.name.len * 7 + 16;
    var legend_x: isize = @as(isize, @intCast(width - right)) - @as(isize, @intCast(legend_width));
    for (tools, 0..) |tool, index| {
        try w.print(
            "<rect x=\"{d}\" y=\"16\" width=\"12\" height=\"12\" rx=\"2\" fill=\"{s}\"/>\n",
            .{ legend_x, toolColor(tools, index) },
        );
        try w.print(
            "<text x=\"{d}\" y=\"26\" font-size=\"12\" fill=\"#1f2328\">",
            .{legend_x + 18},
        );
        try svgEscape(w, tool.name);
        try w.writeAll("</text>\n");
        legend_x += @intCast(12 + 6 + tool.name.len * 7 + 16);
    }

    if (groups.items.len > 0) {
        const fractions = [_]f64{ 0.0, 0.25, 0.5, 0.75, 1.0 };
        for (fractions) |fraction| {
            const x = @as(f64, @floatFromInt(left)) + @as(f64, @floatFromInt(plot_width)) * fraction;
            try w.print(
                "<line x1=\"{d:.1}\" y1=\"{d}\" x2=\"{d:.1}\" y2=\"{d}\" stroke=\"#d0d7de\" stroke-width=\"1\"/>\n",
                .{ x, top, x, height - bottom },
            );
            var buffer: [32]u8 = undefined;
            try w.print(
                "<text x=\"{d:.1}\" y=\"{d}\" font-size=\"11\" text-anchor=\"middle\" fill=\"#57606a\">{s}</text>\n",
                .{ x, height - bottom + 18, rssString(&buffer, scale_max * fraction) },
            );
        }

        var y: usize = top;
        for (groups.items) |group| {
            const group_height = group.values.len * (bar_height + bar_gap) - bar_gap;
            try w.print(
                "<text x=\"{d}\" y=\"{d:.1}\" font-size=\"13\" font-weight=\"600\" text-anchor=\"end\" fill=\"#1f2328\">",
                .{ left - 12, @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(group_height)) / 2.0 + 4.0 },
            );
            try svgEscape(w, group.label);
            try w.writeAll("</text>\n");

            for (group.values) |value| {
                const bar_width = @max(
                    2.0,
                    @as(f64, @floatFromInt(plot_width)) * value.value / scale_max,
                );
                var buffer: [32]u8 = undefined;
                const label = rssString(&buffer, value.value);
                try w.print(
                    "<rect x=\"{d}\" y=\"{d}\" width=\"{d:.1}\" height=\"{d}\" rx=\"3\" fill=\"{s}\">" ++
                        "<title>",
                    .{ left, y, bar_width, bar_height, toolColor(tools, value.tool) },
                );
                try svgEscape(w, tools[value.tool].name);
                try w.print(": {s}</title></rect>\n", .{label});
                try w.print(
                    "<text x=\"{d:.1}\" y=\"{d:.1}\" font-size=\"12\" fill=\"#1f2328\">{s}</text>\n",
                    .{
                        @as(f64, @floatFromInt(left)) + bar_width + 8.0,
                        @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(bar_height)) / 2.0 + 4.0,
                        label,
                    },
                );
                y += bar_height + bar_gap;
            }
            y += group_gap;
        }
    } else {
        try w.print(
            "<text x=\"{d}\" y=\"{d}\" font-size=\"13\" fill=\"#57606a\">No peak RSS data</text>\n",
            .{ left, top + 20 },
        );
    }

    try w.writeAll("</svg>\n");
    return allocating.written();
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn absolutePath(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') return path;
    if (builtin.os.tag == .windows and path.len > 1 and path[1] == ':') return path;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.currentPath(io, &buffer) catch return path;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ buffer[0..cwd], path });
}

fn isDirectory(io: Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn currentTimeUtc(io: Io, buffer: []u8) []const u8 {
    const timestamp = Io.Clock.real.now(io);
    const seconds = timestamp.toSeconds();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(@max(0, seconds)),
    };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch "unknown";
}

fn buildTools(arena: Allocator, config: *const Config) ![]Tool {
    var tools: std.ArrayList(Tool) = .empty;
    if (config.kazu.len > 0) {
        try tools.append(arena, .{ .name = "kazu", .path = config.kazu, .kind = .kazu });
    }
    if (config.kazu_base.len > 0) {
        try tools.append(arena, .{ .name = "kazu-base", .path = config.kazu_base, .kind = .kazu });
    }
    for (config.kazu_variants.items) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try tools.append(arena, .{
            .name = entry[0..eq],
            .path = entry[eq + 1 ..],
            .kind = .kazu,
        });
    }
    if (config.scc.len > 0) {
        try tools.append(arena, .{ .name = "scc", .path = config.scc, .kind = .scc });
    }
    if (config.tokei.len > 0) {
        try tools.append(arena, .{ .name = "tokei", .path = config.tokei, .kind = .tokei });
    }
    if (config.mezura.len > 0) {
        try tools.append(arena, .{ .name = "mezura", .path = config.mezura, .kind = .mezura });
    }

    for (tools.items) |*tool| {
        for (config.describes.items) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..eq], tool.name)) tool.description = entry[eq + 1 ..];
        }
    }
    return tools.items;
}

fn runBench(
    arena: Allocator,
    io: Io,
    config: *const Config,
    tools: []const Tool,
) ![]RepoResult {
    const repos = try arena.alloc(RepoResult, config.repos.items.len);

    for (config.repos.items, 0..) |entry, repo_index| {
        const eq = std.mem.indexOfScalar(u8, entry, '=').?;
        const label = entry[0..eq];
        const path = try absolutePath(arena, io, entry[eq + 1 ..]);

        std.debug.print("\n== {s} ({s})\n", .{ label, path });

        const summaries = try arena.alloc(Summary, tools.len);
        for (summaries) |*summary| summary.* = .{};
        repos[repo_index] = .{
            .label = label,
            .path = path,
            .summaries = summaries,
        };

        if (!isDirectory(io, path)) {
            repos[repo_index].err = try std.fmt.allocPrint(arena, "checkout not found: {s}", .{path});
            std.debug.print("   skipped: {s}\n", .{repos[repo_index].err.?});
            continue;
        }

        const commands = try arena.alloc([]const []const u8, tools.len);
        for (tools, 0..) |tool, index| {
            commands[index] = try buildCommand(arena, tool, path, config.*);
        }

        const runs = try arena.alloc(std.ArrayList(Run), tools.len);
        for (runs) |*list| list.* = .empty;
        const errors = try arena.alloc(?[]const u8, tools.len);
        @memset(errors, null);
        const counts = try arena.alloc(?Counts, tools.len);
        @memset(counts, null);

        // Warm the page cache and confirm each tool runs before timing it.
        for (tools, 0..) |_, index| {
            switch (try runTimed(arena, io, commands[index], config.timeout_s)) {
                .ok => {},
                .failed => |message| errors[index] = message,
            }
        }

        for (0..config.rounds) |round| {
            for (0..tools.len) |step| {
                const index = if (round % 2 == 0) step else tools.len - 1 - step;
                if (errors[index] != null) continue;
                switch (try runTimed(arena, io, commands[index], config.timeout_s)) {
                    .ok => |run| try runs[index].append(arena, run),
                    .failed => |message| errors[index] = message,
                }
            }
        }

        for (tools, 0..) |tool, index| {
            if (errors[index] != null) continue;
            switch (try runCapture(arena, io, commands[index], tool.kind, config.timeout_s)) {
                .ok => |value| counts[index] = value,
                .failed => |message| errors[index] = message,
            }
        }

        for (tools, 0..) |tool, index| {
            summaries[index] = try summarize(arena, runs[index].items, counts[index], errors[index]);
            if (errors[index]) |message| {
                std.debug.print("   {s}: FAILED {s}\n", .{ tool.name, message });
            } else if (summaries[index].wall) |wall| {
                if (wall.median >= 1000.0) {
                    std.debug.print("   {s}: {d:.2} s\n", .{ tool.name, wall.median / 1000.0 });
                } else if (wall.median >= 100.0) {
                    std.debug.print("   {s}: {d:.0} ms\n", .{ tool.name, wall.median });
                } else {
                    std.debug.print("   {s}: {d:.1} ms\n", .{ tool.name, wall.median });
                }
            }
        }
    }

    return repos;
}

fn appendFile(arena: Allocator, io: Io, path: []const u8, text: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const existing = dir.readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const combined = try std.mem.concat(arena, u8, &.{ existing, text });
    try dir.writeFile(io, .{ .sub_path = path, .data = combined });
}

fn writeStdout(io: Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try writeStdout(io, help_text);
            return;
        }
    }

    const config = parseArgs(arena, args) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(2),
        else => return err,
    };

    const tools = try buildTools(arena, &config);
    for (tools) |*tool| {
        tool.version = toolVersion(arena, io, tool.path);
    }

    var time_buffer: [32]u8 = undefined;
    const generated_at = currentTimeUtc(io, &time_buffer);

    std.debug.print("benchmark tools:\n", .{});
    for (tools) |tool| {
        std.debug.print("  {s}: {s} ({s})", .{ tool.name, tool.version, tool.path });
        if (tool.description) |description| std.debug.print(" [{s}]", .{description});
        std.debug.print("\n", .{});
    }
    if (config.workers == 0) {
        std.debug.print("rounds: {d}, kazu workers: default\n", .{config.rounds});
    } else {
        std.debug.print("rounds: {d}, kazu workers: {d}\n", .{ config.rounds, config.workers });
    }
    std.debug.print("by-file: {s}, no-gitignore: {s}\n", .{
        if (config.by_file) "true" else "false",
        if (config.no_gitignore) "true" else "false",
    });

    const repos = try runBench(arena, io, &config, tools);

    const report: Report = .{
        .generated_at = generated_at,
        .rounds = config.rounds,
        .workers = config.workers,
        .options = .{ .by_file = config.by_file, .no_gitignore = config.no_gitignore },
        .tools = tools,
        .repos = repos,
    };

    if (config.json_path) |path| {
        const json = try renderJson(arena, &report);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    }

    const svg_name = if (config.svg_path) |path| std.fs.path.basename(path) else null;
    const markdown = try renderMarkdown(arena, &report, svg_name);
    if (config.markdown_path) |path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = markdown });
    }
    if (config.summary_path) |path| {
        try appendFile(arena, io, path, markdown);
    }
    if (config.svg_path) |path| {
        const svg = try renderSvg(arena, &report);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = svg });
    }

    var failed_repos: usize = 0;
    var failed_tools: usize = 0;
    for (repos) |repo| {
        if (repo.err != null) failed_repos += 1;
        for (repo.summaries) |summary| {
            if (summary.err != null) failed_tools += 1;
        }
    }
    if (failed_repos > 0 or failed_tools > 0) {
        std.debug.print(
            "\ncompleted with failures: {d} repo(s), {d} tool run(s)\n",
            .{ failed_repos, failed_tools },
        );
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseTest(kind: ToolKind, json: []const u8) !Counts {
    var reader = std.Io.Reader.fixed(json);
    var walker: Walker = .init(std.testing.allocator, &reader);
    defer walker.deinit();
    return parseWith(kind, &walker);
}

test "kazu rows sum per-language totals" {
    const counts = try parseTest(.kazu,
        \\[{"Name":"Zig","Files":2,"Lines":10,"Blank":1,"Comment":2,"Code":7},
        \\ {"Name":"C","Files":1,"Lines":5,"Blank":0,"Comment":1,"Code":4}]
    );
    try std.testing.expectEqual(@as(u64, 3), counts.files);
    try std.testing.expectEqual(@as(u64, 15), counts.lines);
    try std.testing.expectEqual(@as(u64, 11), counts.code);
    try std.testing.expectEqual(@as(u64, 3), counts.comments);
    try std.testing.expectEqual(@as(u64, 1), counts.blanks);
}

test "scc skips the Total row and nested file reports" {
    const counts = try parseTest(.scc,
        \\[{"Name":"Zig","Lines":10,"Code":7,"Comment":2,"Blank":1,"Count":2,
        \\  "Files":[{"Lines":5,"Code":3,"Comment":1,"Blank":1},
        \\           {"Lines":5,"Code":4,"Comment":1,"Blank":0}]},
        \\ {"Name":"Total","Lines":10,"Code":7,"Comment":2,"Blank":1,"Count":2}]
    );
    try std.testing.expectEqual(@as(u64, 2), counts.files);
    try std.testing.expectEqual(@as(u64, 10), counts.lines);
    try std.testing.expectEqual(@as(u64, 7), counts.code);
}

test "tokei counts reports and reads the Total object" {
    const counts = try parseTest(.tokei,
        \\{"Zig":{"blanks":2,"code":8,"comments":1,"reports":[{"stats":{},"name":"a.zig"},{"stats":{},"name":"b.zig"}],"children":{},"inaccurate":false},
        \\ "Total":{"blanks":2,"code":8,"comments":1,"reports":[],"children":{"Zig":[{"stats":{},"name":"a.zig"}]}}}
    );
    try std.testing.expectEqual(@as(u64, 2), counts.files);
    try std.testing.expectEqual(@as(u64, 11), counts.lines);
    try std.testing.expectEqual(@as(u64, 8), counts.code);
    try std.testing.expectEqual(@as(u64, 1), counts.comments);
    try std.testing.expectEqual(@as(u64, 2), counts.blanks);
}

test "mezura reads the total object and falls back to extra" {
    const counts = try parseTest(.mezura,
        \\{"total":{"files":3,"lines":9,"code":6,"comments":1,"extra":2},"languages":[]}
    );
    try std.testing.expectEqual(@as(u64, 3), counts.files);
    try std.testing.expectEqual(@as(u64, 9), counts.lines);
    try std.testing.expectEqual(@as(u64, 6), counts.code);
    try std.testing.expectEqual(@as(u64, 1), counts.comments);
    try std.testing.expectEqual(@as(u64, 2), counts.blanks);
}

test "an empty object parses as zero counts" {
    const counts = try parseTest(.tokei, "{}");
    try std.testing.expectEqual(@as(u64, 0), counts.files);
    try std.testing.expectEqual(@as(u64, 0), counts.lines);
}

test "empty output is a parse error, not zero counts" {
    try std.testing.expectError(error.UnexpectedEndOfInput, parseTest(.tokei, ""));
}

test "describe returns the median and sample deviation" {
    var values = [_]f64{ 3.0, 1.0, 2.0 };
    const stats = describe(&values);
    try std.testing.expectEqual(@as(usize, 3), stats.n);
    try std.testing.expectEqual(@as(f64, 2.0), stats.median);
    try std.testing.expectEqual(@as(f64, 2.0), stats.mean);
    try std.testing.expectEqual(@as(f64, 1.0), stats.stdev);
    try std.testing.expectEqual(@as(f64, 1.0), stats.min);
    try std.testing.expectEqual(@as(f64, 3.0), stats.max);
}

test "count strings use thousands separators" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", countString(&buffer, 0));
    try std.testing.expectEqualStrings("999", countString(&buffer, 999));
    try std.testing.expectEqualStrings("1,000", countString(&buffer, 1000));
    try std.testing.expectEqualStrings("1,234,567", countString(&buffer, 1234567));
}

test "peak rss strings switch to gibibytes" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("7.0 MiB", rssString(&buffer, 7168));
    try std.testing.expectEqualStrings("1.00 GiB", rssString(&buffer, 1024 * 1024));
}

test "rss bars keep a visible minimum" {
    try std.testing.expectEqual(@as(usize, 24), rssBar(10.0, 10.0, 24));
    try std.testing.expectEqual(@as(usize, 12), rssBar(5.0, 10.0, 24));
    try std.testing.expectEqual(@as(usize, 1), rssBar(0.01, 10.0, 24));
    try std.testing.expectEqual(@as(usize, 0), rssBar(0.0, 10.0, 24));
}
