# AGENTS.md

Guidance for agents working in this repository.

## Project

`kazu` is a fast, parallel source code counter written in Zig, modeled on
[`scc`](https://github.com/boyter/scc) and `cloc`. It walks a tree, detects each
file's language, classifies every line as code, comment, or blank, and reports
per-language totals.

- Zig **0.17.1**, no libc dependency in the default static build.
- No runtime dependencies: concurrency and file I/O both come from `std.Io`.
- The public library surface is `src/root.zig`; the CLI is `src/main.zig`.

## Commands

| Task | Command |
| --- | --- |
| Build (release) | `zig build -Doptimize=fast` |
| Run | `./zig-out/bin/kazu .` |
| Fast test loop | `zig test src/root.zig` |
| Full test step | `zig build test` |
| Format | `zig fmt src/*.zig build.zig` |
| Format check | `zig fmt --check src/*.zig build.zig` |

Native `zig build` works on Termux; no target override is needed now that the
`zio` dependency is gone. `zig test src/root.zig` is the quickest way to
validate library changes. Host-specific notes live in `ENVIRONMENT.local.md`
(local, gitignored).

`zig build test` builds two test executables: one for the library module
(`src/root.zig`) and one for the CLI module (`src/main.zig`). Both must pass.

## Layout

| File | Responsibility |
| --- | --- |
| `src/main.zig` | CLI parsing, selective `std.Io` directory walk, `.gitignore` / `.ignore` integration, batched `std.Io` workers |
| `src/root.zig` | Public module; re-exports the pure modules and pulls in their tests |
| `src/languages.zig` | Language table plus filename/extension/shebang detection |
| `src/rapidhash.zig` | Vendored rapidhash V3 case-folded hash used by the language map |
| `src/count.zig` | Line classification and counting |
| `src/gitignore.zig` | `.gitignore` / `.ignore` parser and path matcher |
| `src/format.zig` | Table, JSON, Markdown, HTML, and ZON renderers |
| `README.md` | User-facing docs: flags, output formats, counting rules |
| `.github/workflows/bench.yml` | Manual benchmark workflow: `kazu` vs `scc` vs `tokei` vs `mezura` |
| `.github/scripts/bench.py` | Interleaved benchmark driver used by the workflow |

## Data flow

1. `walkRoot` stats each CLI path, opens a directory handle, and hands it to
   `walkDir`.
2. `walkDir` drives `std.Io.Dir.walkSelectively`. It prunes excluded and
   ignored directories *before* calling `enter`, so skipped trees are never
   opened, and loads each directory's `.gitignore` then `.ignore` as it
   descends. Entries carry a root-relative path; the walker owns the directory
   handles.
3. `queueFile` applies `--include-ext` / `--exclude-ext`, detects the language
   from the basename, and appends a `FileTask` to the current batch. It takes
   ownership of the path string; the batch frees it. It returns whether the
   file was queued, which lets `queueWalked` record the canonical path in the
   `--include-symlinks` dedup set only for counted files.
4. `Batcher.flush` splits one batch (4096 files) across a short-lived
   `std.Io.Group` with one `std.atomic.Value(usize)` counter. Workers read the
   file in 64 KiB chunks through `std.Io` (or sniff a `#!` line when the
   language is unknown), reject a file whose first 10,000 bytes contain a NUL,
   and feed the rest to `count.Counter`. Each worker owns one reusable read
   buffer; nothing is allocated per file. Results are written into a pre-sized
   slot array, so no channel or collector is involved.
5. After `Group.await`, the batcher frees the paths and folds each
   `FileResult` into the `format.Summary` for its language. With `--by-file`
   it instead hands each counted path to a `FileSummary` list; that list owns
   the strings and frees them after the report is written.
6. `format.writeReport` renders the selected format. Per-file mode passes the
   file list alongside the language rows: table/Markdown/HTML nest file rows
   under their language, while JSON/ZON emit a flat per-file array.

Keep counting and formatting logic out of `main.zig`; it should stay
orchestration-only so the pure modules remain testable.

## Code conventions

- Run `zig fmt` before finishing. Four-space indent, standard Zig style.
- Each file starts with a `//!` module doc comment explaining its role.
- Tests live at the bottom of the file that owns the code, named
  `test "lowercase description"`. Use `std.testing.expectEqual` with explicit
  casts (`@as(u64, 1)`).
- Prefer explicit error handling. CLI misuse returns `error.InvalidArgs` via
  `invalid(...)`, which prints to stderr and makes `main` exit with code 2.
- Per-file failures are non-fatal: log with `std.log.debug` and skip.
- Allocator discipline matters. `run` uses the GPA from `std.process.Init`;
  path strings are owned by whoever receives them. `queueFile` frees paths it
  rejects, `Batcher.push` frees the path even when appending fails, and
  `flush`/`deinit` free every accepted path. `queueWalked` frees the path when
  the dedup set already holds it.
- Avoid allocations in the hot path (`countLines` and `Counter.feed` work on
  borrowed slices; `Counter` carries at most `max_marker_len` bytes between
  chunks).

## Language table rules (`src/languages.zig`)

This is the most edit-prone file. Preserve these invariants:

- **Order matters.** Detection is first-match-wins. The table is grouped by
  language family for readability, but the effective precedence is top-down.
- Extensions are lowercase and stored **without** a leading dot. Filenames are
  matched case-insensitively against the basename.
- Reuse the shared marker constants at the top of the file (`slash`, `hash`,
  `c_block`, `html_block`, ...) instead of re-declaring literals.
- `quotes` lists characters that open string literals so comment markers inside
  strings are ignored. `line_prefixes` marks lines that are code without
  scanning (used for Zig `\\` multiline strings).
- `detectName` tries the filename first, then the **longest** dotted suffix
  first, so compound extensions (`d.ts`, `blade.php`, `vcxproj.filters`,
  `cs.st`) beat their final component. Do not replace it with
  `std.fs.path.extension`. `detectBasename` is the same logic for callers that
  already hold a basename; the walker uses it to avoid recomputing the basename.
- Filename and extension lookups use a comptime open-addressed map keyed by
  `rapidhash.hashFold`: the hash folds ASCII case into each loaded word, and
  every probe finishes with `std.ascii.eqlIgnoreCase`, so lookups never
  allocate or copy the key. Duplicate keys keep the first language, preserving
  top-down precedence. `src/rapidhash.zig` is a trimmed, vendored rapidhash V3
  (MIT) that keeps only `hashFold` and its helpers.
- Tests guard the table and must keep passing:
  - `every language has a detection rule` — each entry needs an extension or a
    filename.
  - `language table has unique extensions` — no extension may be claimed twice.
  - `every extension and filename maps to its language` — every key resolves to
    its entry, including when the input is uppercase.
- When two `scc` languages share an extension, keep the language `kazu` already
  assigns and merge the remaining extensions into it rather than adding a
  duplicate. Current decisions: `m` → Objective-C, `h` → C, `ts` → TypeScript,
  `v` → Verilog.
- The table covers `scc` 4.1.0, including text/data pseudo-languages (`Plain
  Text`, `CSV`, `License`, `Jupyter`, `Patch`, `gitignore`, `ignore`,
  `Docker ignore`). This is intentional; do not silently drop them.
  `gitignore` and `ignore` remain detectable, but `isIncludedFile` filters
  `.gitignore` / `.ignore` out of the count so `kazu` matches `scc`;
  `.dockerignore` is still counted as `Docker ignore`.

## Counting semantics (`src/count.zig`)

- Whitespace-only line → blank.
- Only comment text → comment.
- Any code, even with a trailing comment → code.
- Block comments persist across lines; block markers are checked before line
  markers.
- Markers inside string literals are ignored.
- A file with no trailing newline still counts its last line.

These match `scc`/`cloc`. Any change needs a corresponding test.

## Adding a language

1. Find the definition in `scc` 4.1.0 (`scc -l` for the token list, and
   `languages.json` from the `v4.1.0` tag for markers).
2. Check whether the extension or filename is already claimed:
   `grep -n '"<token>"' src/languages.zig`. If so, extend the existing entry.
3. Append the new entry at the end of the table (after the
   `// Additional languages supported by scc` comment) with lowercase
   extensions, no leading dot.
4. Use the shared comment/block constants where they match.
5. Add detection coverage to `test "detect languages added from scc"` and, if
   the markers are unusual, a counting test in `src/count.zig`.
6. Run `zig test src/root.zig`, then `zig build test`.

## Validating against `scc`

`scc` 4.1.0 is installed. Use these flags so the comparison is apples-to-apples:

```sh
scc --no-complexity --no-cocomo --no-gitignore --no-ignore --no-scc-ignore --format json <path>
./zig-out/bin/kazu --no-gitignore --no-ignore --format json <path>
```

`kazu` emits `Name`/`Files`; `scc` emits `Name`/`Count`. Known, accepted
divergences:

- `kazu` counts `.zon` as Zig; `scc` does not.
- `kazu` skips `.zig-cache`; `scc` descends into it.
- `scc` 4.1.0's ABAP entry uses a literal `\"` marker, so it misses real ABAP
  `"` comments. `kazu` handles them.
- `scc` 4.1.0 misclassifies Zig `\\` multiline strings and `'"'` character
  literals (fixed upstream later); this shifts code/comment counts, not file
  sets.

## Benchmarking

Single-shot timings are meaningless on a shared host.

- Prefer an **interleaved** driver: alternate the commands each round and
  report medians, so drift affects every tool equally.
- See `ENVIRONMENT.local.md` (local, gitignored) for this machine's CPU
  topology, throttling behaviour, and sandbox quirks.
- `hyperfine -S --warmup 5 --runs 50` is a useful cross-check. `-S` is required
  because the commands contain `>` redirection.
- Report wall clock, CPU time, and peak RSS separately; `kazu` trades more CPU
  for far less memory.
- Standard workloads: `src`, `/root/LangArena` (source-only and full), a flat
  source tree, a large single file, and synthetic dir-heavy trees. Use
  `--no-gitignore --no-ignore` on kazu and
  `--no-gitignore --no-ignore --no-scc-ignore` on scc.
- Record results in `BENCHMARKS.md`. That file also holds the `scc` 4.1.0
  comparison and the scanner/read-buffer baselines; refresh it after changing
  the scanner, the I/O path, or the worker pool.
- `.github/workflows/bench.yml` is the repeatable cross-tool comparison. It is
  `workflow_dispatch`-only, shallow-clones the requested repositories, and runs
  all four tools with their default ignore behaviour (no `--no-gitignore`)
  unless the `no_gitignore` input is enabled, which adds
  `--no-gitignore --no-ignore` for kazu,
  `--no-gitignore --no-ignore --no-scc-ignore` for scc, `--no-ignore` for
  tokei, and `--no-gitignore --no-ignore-files` for mezura. The `by_file` input
  switches all four tools to per-file output (`--by-file` for kazu/scc/mezura,
  `--files` for tokei; tokei's JSON always includes per-file reports). The
  `kazu_refs` input builds extra kazu commits with the same Zig version in
  detached worktrees and passes them to the driver as
  `--kazu-variant kazu-<short sha>=<path>`; the checked-out commit stays the
  `kazu` baseline, and every ratio is measured against it. Each tool's commit
  SHA and subject are passed through `--describe`, so the report and job summary
  identify the exact builds. The workflow builds scc and mezura from source
  (`go build` for scc and `cargo build --release --bin mezura` for mezura);
  locally, point `--scc` / `--mezura` at existing binaries instead. The driver
  runs mezura with
  `--counting region`, `--count-minified`, `--count-generated`,
  `--count-not-code`, and `--search-in-dotted` so it uses the same line model
  and file set as the other tools. The `combined` input adds one scan of the
  clone parent, so the tools are also measured on a single large tree.
  `bench.py --svg` writes a grouped peak-RSS bar chart; the workflow attaches
  it as `bench-memory.svg` and also renders a text bar chart in the Markdown
  report (GitHub strips inline SVG from Markdown).
- `.github/workflows/bench-compare.yml` is the head-vs-base comparison for
  `kazu` alone. It accepts the same repository/round/worker/toggle inputs plus
  `base_ref` (default `HEAD^`), builds the head and a detached-worktree build of
  the base with the same Zig version, and passes both binaries to `bench.py` via
  `--kazu` and `--kazu-base`. Both builds use `-Dstrip` to keep the binaries
  small; the base build falls back to no strip when the older commit does not
  define the option. The built binaries are cached with `actions/cache` under
  keys that include the commit SHA, Zig version, and strip flag, so reruns skip
  the rebuild. The driver interleaves the selected tools each
  round (forward, then reversed) and derives the report title from the tool
  list, so a two-binary run reports `# kazu vs kazu-base`. The head and base
  commit short SHA and subject are passed with `--describe` and also printed in
  the job summary's environment block. `--kazu-base` is empty by default, so the
  cross-tool workflow is unchanged.

## Gotchas

- Symlinks are not followed by default, and non-regular files (FIFOs, sockets,
  devices) are always skipped. `.unknown` directory entries are stat'ed without
  following symlinks so they resolve to a real file, directory, or skip.
- `--include-symlinks` counts symlinked files. The walk never enters a
  symlinked directory (that matches `scc` and avoids cycles); an explicit
  symlink root is followed. `SymlinkDedup` keys walked files by
  `<root real path>/<relative path>` and symlinks by their resolved target, so
  a link that resolves to a file already counted is skipped. It is only
  allocated when the flag is set.
- A file with a NUL byte in its first 10,000 bytes is skipped as binary. `scc`
  applies that check only in its C and Java counters and misses a NUL at the
  start of a line, so `kazu` skips some files `scc` counts; this is intentional.
- Lockfiles matching `scc`'s default `--exclude-file` list are skipped
  (`package-lock.json`, `Cargo.lock`, `yarn.lock`, `pubspec.lock`,
  `Podfile.lock`, `pnpm-lock.yaml`). The match is a substring of the basename.
- Files over 256 MiB are skipped with a warning; ignore files over 1 MiB are
  ignored.
- `--include-ext` filters on the file extension, so extensionless files (which
  rely on shebang detection) are excluded when it is set.
- `--exclude-dir` matches directory names, not paths, and defaults already
  cover `.git`, `node_modules`, `zig-out`, `.zig-cache`, `target`, and similar.
- File reads must stay on `std.Io` (`openFile` / `readPositional`), not a raw
  POSIX `pread` loop: `std.Io` is what keeps the tool portable, and its threaded
  backend runs the syscall inline in the calling thread.
- Do not reintroduce a per-file `std.Io.Queue`/channel between the walker and
  the workers. Every send/receive is a futex pair; on directory-heavy trees that
  produced ~35k futex calls and was 1.9-2.5x slower. The batch + atomic counter
  design exists specifically to avoid it.
- `std.Io.Group.concurrent` spawns OS threads on the threaded backend, so a
  batch of 4096 files costs at most `--workers` spawns. Keep the batch large
  enough to amortize that; do not flush per directory.
- The walk must stay on `std.Io.Dir.walkSelectively`, not a recursive helper.
  `enter` is what descends, so an excluded or ignored directory is pruned with
  a single readdir entry and never opened. Ignore-file scope is tracked by
  entry depth because the walker pops exhausted directories internally without
  a callback. `.ignore` is loaded after `.gitignore` in the same directory so
  its rules win.
- The `README.md` "Layout" and flag table must stay in sync with `help_text` in
  `src/main.zig` and the option parsing.
