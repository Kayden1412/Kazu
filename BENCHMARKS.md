# Benchmarks

Performance results for `kazu`, recorded so future changes can be compared
against a known baseline. Re-run the workloads below after touching the
scanner, the I/O path, the walk, or the worker pool.

- **Recorded:** 2026-10-29
- **kazu:** 0.1.0, Zig 0.17.0, `-Doptimize=fast`, `aarch64-linux-musl`
- **scc:** 4.1.0

> Host-specific notes (CPU topology, throttling, sandbox quirks) are kept in
> `ENVIRONMENT.local.md`, which is local and gitignored.

## Method

Both tools were run with JSON output redirected to `/dev/null`, alternating
which tool ran first each round. Reported values are medians of 7–15 rounds.
CPU time is `user + sys` from `wait4`; RSS is `ru_maxrss`.

```sh
# kazu
./zig-out/bin/kazu --no-gitignore --format json <path>

# scc
scc --no-complexity --no-cocomo --no-gitignore --format json <path>
```

Build:

```sh
zig build -Doptimize=fast -Dtarget=aarch64-linux-musl
```

## kazu vs scc 4.1.0

| Workload | kazu | scc | kazu/scc wall | kazu CPU | scc CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| empty dir (startup) | 10.1 ms | 199.4 ms | **0.05x** | 4.4 ms | 101.8 ms |
| tiny 1 file | 11.8 ms | 197.1 ms | **0.06x** | 5.3 ms | 109.1 ms |
| `kazu src` (6 files) | 18.2 ms | 212.2 ms | **0.09x** | 11.4 ms | 121.7 ms |
| `zio src` (112 files) | 54.6 ms | 226.4 ms | **0.24x** | 48.5 ms | 200.8 ms |
| flat-src (364 files, 2.6 MB) | 102.5 ms | 331.3 ms | **0.31x** | 70.4 ms | 263.1 ms |
| LangArena (960 on disk, 10.6 MB) | 358.9 ms | 592.6 ms | **0.61x** | 211.9 ms | 537.0 ms |
| LangArena x4 (3724 on disk, 51 MB) | 1241.0 ms | 1596.2 ms | **0.78x** | 862.1 ms | 1768.4 ms |
| 3724 empty `.c` files | 878.8 ms | 1517.3 ms | **0.58x** | 465.1 ms | 987.1 ms |
| `code10m.c` (10 MiB, 1 line) | 27.7 ms | 212.1 ms | **0.13x** | 21.8 ms | 135.3 ms |
| `line16m.py` (16 MiB, 1 line) | 37.6 ms | 188.9 ms | **0.20x** | 30.4 ms | 122.1 ms |
| `line64m.c` (64 MiB, 1 line) | 110.9 ms | 360.3 ms | **0.31x** | 105.0 ms | 292.6 ms |

Ratios below `1.00x` mean kazu is faster.

### Memory

| Workload | kazu RSS | scc RSS |
| --- | ---: | ---: |
| `code10m.c` | 7.1 MB | 29.7 MB |
| `line16m.py` | 7.1 MB | 35.9 MB |
| `line64m.c` | 7.1 MB | 85.2 MB |
| flat-src | 7.1 MB | 24.2 MB |
| `kazu src` | 7.1 MB | 20.1 MB |
| `zio src` | 7.1 MB | 22.4 MB |
| LangArena | 7.1 MB | 33.9 MB |
| LangArena x4 | 7.1 MB | 37.8 MB |

kazu stays flat at roughly **7.1 MB**; scc ranges **20–85 MB**.

### How to read this

**Startup dominates the small rows.** kazu's empty-directory scan is ~10 ms,
while `scc` pays a much larger fixed process-startup cost. The 0.05x–0.09x
entries therefore mostly measure startup, not counting speed; on a host with a
cheaper process floor scc's small-row times would be much lower.
Dropping zio also removed the runtime/executor setup that used to cost kazu
~18 ms of its ~28 ms startup floor.

**Large trees are ahead of scc.** On LangArena x4 kazu is 0.78x scc's wall
time; LangArena itself is 0.61x. The empty-file run shows the per-file cost:

- 3724 empty files: kazu **~233 µs/file**, scc **~354 µs/file** (after
  subtracting startup)
- LangArena x4 with content: kazu **~330 µs/file**, scc **~375 µs/file**
- Effective throughput on 51 MB / 3724 files: kazu ~**41 MB/s**, scc ~**37 MB/s**

The remaining x4 cost is scanner/CPU-bound; walking and I/O bookkeeping are no
longer dominant.

### Counting parity

The two tools scan slightly different file sets because of pre-existing
language-table decisions, not because of the scanner. On LangArena:

- kazu: 788 files, 332,907 lines
- scc: 769 files, 332,605 lines (0.09% fewer lines)

Differences come from `C Header`/`C++ Header` splitting, `sh` → Shell vs BASH,
and INI/JSON handling. See `AGENTS.md` for the extension decisions.

## Removing zio: batched `std.Io` workers

The previous design used zio for the worker pool and a bounded
`zio.Channel(FileTask)` feeding `zio.Channel(FileResult)`. Once the walk and all
file reads moved to `std.Io`, zio was only providing a channel and a way to
spawn workers, so it was replaced with the standard library.

A naive port that swapped in `std.Io.Queue` plus `std.Io.Group` was **slower**
(1.4–2.5x), not faster. Every `putOne`/`getOne` locks an `Io.Mutex` and may
sleep on an `Io.Condition`, i.e. a futex pair per file. On the 3724-file tree
the port made **34,909 futex calls** versus **136** for the zio build; the
wakeup traffic dominated the actual counting.

The adopted design keeps the queue out of the hot path:

1. The walker appends `FileTask`s to a `std.ArrayList` batch (4096 files).
2. `Batcher.flush` runs one `std.Io.Group.concurrent` per worker for the whole
   batch. Workers pull the next index with a single
   `std.atomic.Value(usize).fetchAdd`, so work distribution is dynamic and
   costs one atomic per file — no lock, no futex, no channel.
3. Each worker writes its `FileResult` into a pre-sized slot of a result array,
   so no result channel or collector task exists.
4. After `Group.await` the batcher folds the results into the per-language
   summaries and frees the paths.

A batch therefore costs at most `--workers` thread spawns instead of ~2N
channel wakeups. If no worker can be spawned (for example a single-threaded
`Io`), the batch is counted on the main thread.

Interleaved zio-vs-batch comparison, medians of 9–15 rounds:

| Workload | zio pipeline | batched `std.Io` | batch/zio | CPU zio | CPU batch |
| --- | ---: | ---: | ---: | ---: | ---: |
| LangArena x4 (3724) | 1360.1 ms | **1198.7 ms** | **0.88x** | 1009.6 ms | 838.7 ms |
| LangArena (960) | 339.4 ms | **277.2 ms** | **0.82x** | 272.2 ms | 214.8 ms |
| flat-src (364) | 120.1 ms | **99.9 ms** | **0.83x** | 85.9 ms | 67.7 ms |
| `zio src` (112) | 80.7 ms | **55.0 ms** | **0.68x** | 70.6 ms | 49.3 ms |
| 3724 empty files | 943.2 ms | **884.8 ms** | **0.94x** | 532.4 ms | 455.6 ms |
| `code10m.c` | 52.4 ms | **35.7 ms** | **0.68x** | 40.6 ms | 32.6 ms |
| `line64m.c` | 135.9 ms | **123.8 ms** | **0.91x** | 122.9 ms | 118.3 ms |
| LangArena x8 (7680) | 3443.6 ms | **3066.2 ms** | **0.89x** | 2025.2 ms | 1715.0 ms |
| dirheavy4 (4000 dirs, 16k files) | 8546.7 ms | **7513.8 ms** | **0.88x** | 5061.0 ms | 3371.4 ms |
| walkheavy (4000 dirs, 100 files) | 3850.8 ms | 3912.3 ms | 1.02x | 1460.4 ms | 1454.8 ms |

The one regression is a synthetic tree with 4000 directories and only 100
files: batching cannot help there, and the extra flush/spawn bookkeeping shows
up as ~1.6%. Every file-bearing tree improved.

Batch worker scaling (wall time, default `-w` is the CPU count):

| Workload | 2 workers | 4 workers | 8 workers |
| --- | ---: | ---: | ---: |
| LangArena x4 | 1683 ms | 1247 ms | **1186 ms** |
| LangArena x8 | 4182 ms | 3154 ms | **3031 ms** |
| LangArena | 480 ms | 374 ms | **365 ms** |
| flat-src | 134 ms | 98 ms | **98 ms** |
| 3724 empty files | 1137 ms | **846 ms** | 864 ms |

Unlike the channel pipeline (where four workers won), the batched design scales
to eight on the larger trees. Keep the default at the CPU count.

The static binary also shrank from **6.8 MB to 4.75 MB**, and RSS stayed at
~7.1 MB (the zio build measured ~6.8 MB, so the difference is within
allocator/page noise).

Output was byte-identical to the zio build on `src`, vendored zio, flat-src,
LangArena, LangArena x4, the 217-language fixture, `line64m.c`, and the
`.gitignore` fixtures.

## Synchronous file reads via `std.Io`

The build before this one read files through zio's async `File` API. With
`.backend = .epoll`, zio probes each descriptor for pollability; regular files
are not pollable, so every `open`, `stat`, `read` and `close` was submitted to
zio's blocking thread pool and the worker task parked until it completed. That
was ~5 thread-pool round trips per file, and it dominated tree scans.

File I/O now goes through the `std.Io` instance from `std.process.Init`. Its
`Threaded` backend executes `openat`, `statx`, `preadv` and `close` **inline in
the calling worker**, on every platform, with no pool hand-off:

```zig
const file = try std.Io.Dir.cwd().openFile(io, task.path, .{});
defer file.close(io);
...
const read_len = try file.readPositional(io, &.{buffer}, offset);
```

Output was byte-identical before and after on `src`, vendored zio, flat-src,
LangArena, LangArena x4, the 217-language fixture, and the 64 MiB long-line
file.

Same-run interleaved comparison, 9 rounds, medians. The `std.Io` column here
still used the old zio walk, so it is the isolated effect of the file path:

| Workload | zio `File` | `std.Io` inline | Speedup | CPU zio | CPU std.Io |
| --- | ---: | ---: | ---: | ---: | ---: |
| LangArena x4 | 3775.3 ms | **1656.5 ms** | **2.28x** | 4181.6 ms | 1259.1 ms |
| 3724 empty files | 2610.0 ms | **1050.6 ms** | **2.48x** | 2859.8 ms | 565.0 ms |
| LangArena | 906.1 ms | **414.7 ms** | **2.19x** | 1023.3 ms | 329.2 ms |
| flat-src | 310.5 ms | **127.1 ms** | **2.44x** | 363.5 ms | 89.2 ms |
| `zio src` | 150.0 ms | **94.3 ms** | **1.59x** | 175.0 ms | 80.7 ms |
| `line64m.c` | 442.8 ms | **144.3 ms** | **3.07x** | 387.4 ms | 128.9 ms |
| `code10m.c` | 103.8 ms | **52.6 ms** | **1.97x** | 84.3 ms | 41.8 ms |

CPU time fell by 2–5x, which confirms the old cost was scheduling/futex
overhead, not the actual read. This mirrors what `scc` does: its
`processor/filereader_unix.go` deliberately uses blocking `syscall.Open` /
`syscall.Read` to avoid Go's runtime poller, whose `epoll_ctl` always fails with
`EPERM` for regular files and costs ~5 wasted syscalls per file.

## Selective `std.Io` walk

The walk had the same problem as file reads. It recursed with `zio.Dir` and
`dir.iterate()`, so every `getdents64` was submitted to zio's blocking thread
pool. Directory descriptors are not pollable either, so a 3724-file tree paid a
thread-pool round trip per readdir.

`walkDir` now drives `std.Io.Dir.walkSelectively`:

```zig
var walker = try std.Io.Dir.walkSelectively(root, gpa);
defer walker.deinit();

while (try walker.next(io)) |entry| {
    if (entry.kind == .directory) {
        if (excluded or ignored) continue; // never opened
        try walker.enter(io, entry);       // descend
    }
}
```

`next` returns a root-relative `entry.path` (valid only until the next call),
and `enter` is the only way to descend. Excluded and gitignored directories are
therefore pruned from the parent's readdir result without an `openat`, `stat`,
or extra syscall. A `strace -e openat` run over a fixture with an 800-directory
ignored subtree showed **zero** opens under the ignored tree for both builds,
but the new walk reaches it with fewer directory operations overall.

`.gitignore` scoping needed care: the selective walker pops exhausted
directories internally and gives the caller no callback. `walkDir` records the
depth of each loaded `.gitignore` and, on every new entry, pops any file whose
depth is at or below the entry's containing directory. This preserves the old
stack semantics (deeper files override shallower ones) without recursion.
`.gitignore` reads also moved to `std.Io` via the containing directory handle.

Interleaved old-vs-new comparison, 15 rounds, medians. "walk" uses
`--include-ext zzz` so files are never queued and the numbers measure the walk
plus startup:

| Workload | walk old | walk new | walk ratio | full old | full new | full ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| LangArena x4 | 448.5 ms | **256.5 ms** | **0.57x** | 1685.0 ms | **1376.0 ms** | **0.82x** |
| LangArena | 106.4 ms | **75.4 ms** | **0.71x** | 411.4 ms | **344.8 ms** | **0.84x** |
| flat-src | 29.3 ms | **27.1 ms** | **0.92x** | 129.6 ms | **125.0 ms** | **0.96x** |
| `zio src` | 40.9 ms | **32.5 ms** | **0.79x** | 94.6 ms | **80.8 ms** | **0.85x** |
| 3724 empty files | 49.5 ms | **43.0 ms** | **0.87x** | 1029.6 ms | **941.9 ms** | **0.91x** |

The walk is now ~19% of the x4 run (256 ms of 1376 ms), down from ~27%
(448 ms of 1685 ms). The full-run gain is smaller than the walk gain because
counting dominates once reads are inline.

Output was byte-identical to the previous binary on `src`, vendored zio,
flat-src, LangArena, LangArena x4, the 217-language fixture, `line64m.c`, and a
purpose-built `.gitignore` fixture covering nested files, negation, directory-
only patterns, anchored patterns, `**`, escaped markers, and an ignored
800-directory subtree.

### Read-buffer experiment (superseded)

An earlier build raised `read_buffer_size` to 1 MiB while still using zio's
async `File` API and gained 1.2–1.9x on large files. **That result no longer
applies.** With inline `std.Io` reads the 1 MiB buffer is 1.07–1.20x *slower*
than 64 KiB on every workload tested, including `line64m.c`, because the cost
was per-chunk thread-pool round trips, not chunk count. Keep 64 KiB.

## Scanner throughput (pre-rewrite vs current)

Measured in isolation with `countLines` on an in-memory buffer, single thread,
`-Doptimize=fast`, best-of-9. This excludes file I/O and startup. Pre-rewrite
numbers come from a copy of `count.zig` saved before the scanner change.

| Fixture | Pre-rewrite | Current | Speedup |
| --- | ---: | ---: | ---: |
| `code10m.c` (10 MiB, 1 line) | 26 MiB/s (385.5 ms) | **934 MiB/s (10.7 ms)** | **36x** |
| `line16m.py` (16 MiB, 1 line) | 40 MiB/s (396.2 ms) | **925 MiB/s (17.3 ms)** | **23x** |
| `line64m.c` (64 MiB, 1 line) | 30 MiB/s (2165.4 ms) | **925 MiB/s (69.2 ms)** | **31x** |
| `comment10m.c` (long line comment) | 268 MiB/s (37.3 ms) | **6358 MiB/s (1.6 ms)** | **24x** |
| `block1m.c` (block comment) | 69 MiB/s (14.4 ms) | 341 MiB/s (2.9 ms) | 4.9x |
| `bytes2m.c` (299,593 short lines) | 30 MiB/s (66.5 ms) | 281 MiB/s (7.1 ms) | 9.3x |
| `lines50k.c` (50,000 lines) | 30 MiB/s (11.2 ms) | 255 MiB/s (1.3 ms) | 8.5x |
| minified JS (443 KB) | 46 MiB/s (9.2 ms) | 225 MiB/s (1.9 ms) | 4.9x |
| `count.zig` (typical source) | 52 MiB/s (0.43 ms) | 275 MiB/s (0.08 ms) | 5.3x |

The current scanner uses a per-language 256-byte `special` table to bulk-skip
ordinary code bytes, plus fast skips for line comments, forced-code lines,
string bodies, and block bodies. Remaining limits are per-line overhead
(~24 ns/line) and string-heavy minified code.

## Conclusions

- kazu beats scc on every measured workload: LangArena x4 0.78x, LangArena
  0.61x, and 0.31x or better on flat and scan-bound inputs.
- kazu's memory advantage is large and stable: ~7.1 MB vs 20–85 MB.
- Dropping zio in favour of batched `std.Io` workers was worth 0.68–0.94x on
  file-bearing trees and removed the last runtime dependency. The binary shrank
  from 6.8 MB to 4.75 MB.
- A per-file `std.Io.Queue` is not a viable substitute for the old channel: it
  produced ~35k futex calls and was 1.9–2.5x slower.
- Inline `std.Io` file reads were worth 1.6–3.1x wall and 2–5x CPU; the old zio
  `File` path was the dominant tree cost.
- The selective `std.Io` walk cut walk time by 0.57–0.92x and full tree time by
  0.82–0.96x. `enter`-based pruning keeps ignored trees from being opened.
- A 1 MiB read buffer is no longer useful; 64 KiB is faster with inline reads.

Suggested follow-ups, in order:

1. Re-run this file's workloads after any scanner, I/O, walk, or worker-pool
   change.
2. Profile the per-file scanner and language detection path; I/O and walking
   are no longer the limiter.
3. Only revisit batching if a workload is dominated by directories rather than
   files (the 4000-dir/100-file tree is the known ~1.6% regression).

## Fixtures

Fixture definitions live in `ENVIRONMENT.local.md` (local, gitignored).
