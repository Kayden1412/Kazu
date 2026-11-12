# kazu

A fast, parallel source code counter in the spirit of [`scc`](https://github.com/boyter/scc) and `cloc`.

`kazu` walks a source tree, detects each file's language, classifies every line as **code**, **comment**, or **blank**, and reports the totals per language. The walk uses `std.Io.Dir.walkSelectively`, so excluded and ignored directories are pruned before they are opened. Files are counted in parallel batches: each batch is split across a group of `std.Io` workers, and every read goes through `std.Io` as well, so the binary has no runtime dependencies beyond Zig's standard library.

## Build

```sh
zig build -Doptimize=fast
./zig-out/bin/kazu .
```

The native build is a static binary; no target override is needed.

## Usage

```text
kazu [options] [path...]
```

With no paths, the current directory is scanned.

| Option | Description |
| --- | --- |
| `-f, --format <fmt>` | Output format: `table` (default), `json`, `md`, `html`, `zon` |
| `-s, --sort <field>` | Sort rows by `files`, `lines`, `blank`, `comments`, `code`, or `name` |
| `-w, --workers <n>` | Number of counting workers (default: CPU count) |
| `--by-file` | Show one row per file instead of per language |
| `--include-symlinks` | Count symlinked files; off by default |
| `--exclude-dir <name>` | Skip a directory name; repeatable |
| `--include-ext <ext>` | Only count these extensions; repeatable |
| `--exclude-ext <ext>` | Skip these extensions; repeatable |
| `--no-gitignore` | Do not read `.gitignore` files |
| `--no-ignore` | Do not read `.ignore` files |
| `-h, --help` | Show help |
| `-v, --version` | Show the version |

Numeric sorts are descending with the language name as a tie-breaker. `name` sorts alphabetically.

With `--by-file`, the same sort is applied to file rows instead, using the path as the tie-breaker; `files` sorts by path because every row is one file. In the table, Markdown, and HTML formats the file rows are grouped under their language summary, with the `Files` column left blank.

### Examples

```sh
# Default table for the current directory
kazu

# JSON report, sorted by line count
kazu --format json --sort lines src tests

# Markdown table for a README, ignoring vendored code
kazu -f md -s files --exclude-dir vendor .

# Only Zig and C sources
kazu --include-ext zig --include-ext c --format html .

# Per-file rows, largest files first
kazu --by-file --sort lines .

# Count symlinked files as well
kazu --include-symlinks .
```

## Output formats

`table` (default):

```text
──────────────────────────────────────────────
Language    Files  Lines  Blank  Comment  Code
──────────────────────────────────────────────
C               1      7      1        2     4
Python          2      8      1        3     4
──────────────────────────────────────────────
Total           3     15      2        5     8
──────────────────────────────────────────────
```

`json` is an array of language objects with scc-style keys:

```json
[
  {
    "Name": "Zig",
    "Files": 5,
    "Lines": 1409,
    "Blank": 156,
    "Comment": 34,
    "Code": 1219
  }
]
```

`md` emits a Markdown table, `html` a complete HTML page containing a table, and `zon` a valid [Zig Object Notation](https://ziglang.org/documentation/master/std/#std.zon) document:

```zig
.{
    .{
        .name = "Zig",
        .files = 5,
        .lines = 1409,
        .blank = 156,
        .comment = 34,
        .code = 1219,
    },
}
```

### Per-file output

`--by-file` adds one row per counted file. The table, Markdown, and HTML formats
list each file under its language summary; the `Files` cell of a file row is
blank because the row describes a single file:

```text
────────────────────────────────────────────────────────────────
Language                  Files  Lines  Blank  Comment  Code
────────────────────────────────────────────────────────────────
Zig                           2     75     10        6    59
src/main.zig                        48      6        4    38
src/count.zig                       27      4        2    21
────────────────────────────────────────────────────────────────
Total                         2     75     10        6    59
────────────────────────────────────────────────────────────────
```

Long paths are truncated from the left and prefixed with `~` so the numeric
columns stay aligned.

`json` and `zon` emit a flat array of file objects instead, each carrying its
own language and a `Files` count of `1`:

```json
[
  {
    "Name": "src/main.zig",
    "Language": "Zig",
    "Files": 1,
    "Lines": 48,
    "Blank": 6,
    "Comment": 4,
    "Code": 38
  }
]
```

The per-file JSON totals still add up to the per-language report, so the output
can be aggregated without rescanning.

## How lines are counted

- A line with only whitespace is **blank**.
- A line with only comment text is a **comment**.
- A line with any code is **code**, even if it also contains a trailing comment.
- Block comments are tracked across lines.
- Comment markers inside string literals are ignored.
- Language detection uses the file name first (for example `Makefile`, `Dockerfile`, `CMakeLists.txt`), then the extension, then a `#!` interpreter line for extensionless scripts. Compound extensions such as `d.ts`, `blade.php`, and `vcxproj.filters` are matched before their final component.

The language table covers the languages and file types recognized by `scc` 4.1.0. When two scc languages share an extension (for example `m` for Objective-C and MATLAB), the extension keeps the language kazu already used.

By default these directories are skipped: `.git`, `.hg`, `.svn`, `node_modules`, `zig-cache`, `.zig-cache`, `zig-out`, `zig-pkg`, `__pycache__`, `.venv`, `venv`, and `target`. These lockfiles are skipped by name: `package-lock.json`, `Cargo.lock`, `yarn.lock`, `pubspec.lock`, `Podfile.lock`, and `pnpm-lock.yaml`. Symlinks are not followed, and non-regular files (FIFOs, sockets, devices) are skipped. Files larger than 256 MiB are skipped with a warning.

`--include-symlinks` counts symlinked files. Symlinked directories are still not entered during a walk, and a symlink that resolves to a file already counted is skipped, so a link inside the tree does not double count its target. An explicit symlink path on the command line is followed instead: a link to a directory is walked, and a link to a file is counted.

Binary files are skipped: a file with a NUL byte in its first 10,000 bytes is treated as binary, the same heuristic `grep`, `git`, and `ripgrep` use. Unlike `scc`, the check applies to every language, not only C and Java.

Files are counted incrementally in fixed-size chunks, so memory use stays flat no matter how large a file or line is.

## Ignore rules

By default, `kazu` reads `.gitignore` and `.ignore` files as it walks the
tree. Both use standard gitignore syntax:

- comments and blank lines
- negation with `!`
- anchored patterns such as `/root.txt` and `doc/*.md`
- directory-only patterns such as `build/`
- `*`, `?`, character classes and `**`

Patterns are matched against paths relative to the scan root. An ignore file
inside a subdirectory applies only below that directory, and its rules override
rules from parent directories. When a directory has both files, `.ignore` is
loaded after `.gitignore`, so its rules win. If a directory itself is ignored,
it is pruned, so negated patterns cannot re-include files inside it (matching
git).

Use `--no-gitignore` or `--no-ignore` to disable one kind of ignore file:

```sh
kazu --no-gitignore .
kazu --no-ignore .
```

`.gitignore` and `.ignore` files are still read for their rules, but they are
not counted as a language. `.dockerignore` is still reported as
`Docker ignore`, matching `scc`.

## Performance

Benchmark methodology and recorded results, including comparisons with `scc`
4.1.0, are in [BENCHMARKS.md](BENCHMARKS.md).

To compare `kazu` against `scc`, `tokei`, and `mezura` on large repositories,
run the **Benchmark** workflow from the Actions tab. It is
`workflow_dispatch`-only and accepts a repository list (`linux`, `zig`, `go`,
`rust`, `ghostty`, or any `owner/name`), an optional ref, the number of rounds,
a worker count, the Zig version, optional scc and mezura refs, whether to add a
combined run, and toggles for per-file output (`--by-file` / `--files`) and for
disabling ignore files on every tool. The workflow shallow-clones each
repository, builds `kazu`, clones and builds `scc` and `mezura` from source
(`go build` and `cargo build --release --bin mezura`), and runs all four tools
with their default ignore-file behaviour unless the ignore toggle is enabled.
With **combined** enabled it also scans the parent directory of every checkout
as one large tree, which approximates a monorepo workload and exercises the
walker, the worker pool, and per-directory ignore-file handling at scale. The
Markdown report is written to the job summary and includes a text bar chart of
peak memory per tool; the Markdown, JSON, and a standalone peak-memory SVG chart
(`bench-memory.svg`) are uploaded as an artifact.

To compare the current commit against an earlier one, run the **Benchmark
compare** workflow. It takes the same repository list, ref, rounds, workers,
Zig version, combined, per-file, and ignore toggles, plus a `base_ref` (default
`HEAD^`). The workflow checks out the repository with full history, builds the
head, creates a detached worktree for the base commit, builds it with the same
Zig toolchain, and times both binaries interleaved on the same checkouts. The
report is written to the job summary and uploaded as `bench-compare.*`. Locally,
the same comparison uses `--kazu` and `--kazu-base`:

```sh
python3 .github/scripts/bench.py \
  --kazu ./zig-out/bin/kazu --kazu-base /path/to/base/kazu \
  --scc "" --tokei "" --mezura "" \
  --repo "kazu=$PWD" --rounds 7 --markdown compare.md
```

The driver runs `mezura` with `--counting region`, `--count-minified`,
`--count-generated`, `--count-not-code`, and `--search-in-dotted` so it uses
the same cloc/tokei/scc line model and counts the files the other tools count;
`--no-default-config --no-local` keep machine and project settings out. If you
already built mezura locally, point the driver at its binary and skip the build.

The same driver runs locally. Pass the parent directory of the checkouts as an
extra `--repo` entry to reproduce the combined run:

```sh
python3 .github/scripts/bench.py \
  --kazu ./zig-out/bin/kazu --scc scc --tokei tokei \
  --mezura /root/mezura/target/release/mezura \
  --repo "kazu=$PWD" --rounds 7 --markdown results.md

# per-repository rows plus one row that scans all checkouts at once
python3 .github/scripts/bench.py \
  --kazu ./zig-out/bin/kazu --scc scc --tokei tokei \
  --mezura /root/mezura/target/release/mezura \
  --repo "linux=/srv/repos/linux" \
  --repo "zig=/srv/repos/zig" \
  --repo "all-repos=/srv/repos" \
  --rounds 7 --markdown results.md
```

Pass `--by-file` and/or `--no-gitignore` to the driver to mirror the workflow
toggles locally; both apply the matching flags to every tool. Add
`--svg results.svg` to write the peak-memory chart next to the report.

## Tests

```sh
zig build test
```

## Layout

- `src/languages.zig` - language table, extension/filename/shebang detection
- `src/count.zig` - line classification and counting
- `src/gitignore.zig` - `.gitignore` / `.ignore` parsing and path matching
- `src/format.zig` - table, JSON, Markdown, HTML, and ZON renderers
- `src/main.zig` - CLI parsing, selective `std.Io` directory walking, and batched `std.Io` workers
- `src/root.zig` - public library module
- `.github/workflows/bench.yml` - manual `kazu` vs `scc` vs `tokei` vs `mezura` benchmark workflow
- `.github/workflows/bench-compare.yml` - manual current-vs-base `kazu` benchmark workflow
- `.github/scripts/bench.py` - interleaved benchmark driver used by the workflow
