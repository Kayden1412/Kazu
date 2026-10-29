# kazu

A fast, parallel source code counter in the spirit of [`scc`](https://github.com/boyter/scc) and `cloc`.

`kazu` walks a source tree, detects each file's language, classifies every line as **code**, **comment**, or **blank**, and reports the totals per language. The walk uses `std.Io.Dir.walkSelectively`, so excluded and gitignored directories are pruned before they are opened. Files are counted in parallel batches: each batch is split across a group of `std.Io` workers, and every read goes through `std.Io` as well, so the binary has no runtime dependencies beyond Zig's standard library.

## Build

```sh
zig build -Doptimize=fast
./zig-out/bin/kazu .
```

On Termux or other systems where Zig cannot find the native libc, build a static musl binary:

```sh
zig build -Doptimize=fast -Dtarget=aarch64-linux-musl
```

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
| `--exclude-dir <name>` | Skip a directory name; repeatable |
| `--include-ext <ext>` | Only count these extensions; repeatable |
| `--exclude-ext <ext>` | Skip these extensions; repeatable |
| `--no-gitignore` | Do not read `.gitignore` files |
| `-h, --help` | Show help |
| `-v, --version` | Show the version |

Numeric sorts are descending with the language name as a tie-breaker. `name` sorts alphabetically.

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

## How lines are counted

- A line with only whitespace is **blank**.
- A line with only comment text is a **comment**.
- A line with any code is **code**, even if it also contains a trailing comment.
- Block comments are tracked across lines.
- Comment markers inside string literals are ignored.
- Language detection uses the file name first (for example `Makefile`, `Dockerfile`, `CMakeLists.txt`), then the extension, then a `#!` interpreter line for extensionless scripts. Compound extensions such as `d.ts`, `blade.php`, and `vcxproj.filters` are matched before their final component.

The language table covers the languages and file types recognized by `scc` 4.1.0. When two scc languages share an extension (for example `m` for Objective-C and MATLAB), the extension keeps the language kazu already used.

By default these directories are skipped: `.git`, `.hg`, `.svn`, `node_modules`, `zig-cache`, `.zig-cache`, `zig-out`, `__pycache__`, `.venv`, `venv`, and `target`. Symlinks are not followed. Files larger than 256 MiB are skipped with a warning.

Files are counted incrementally in fixed-size chunks, so memory use stays flat no matter how large a file or line is.

## Ignore rules

By default, `kazu` reads `.gitignore` files as it walks the tree. Standard
gitignore syntax is supported:

- comments and blank lines
- negation with `!`
- anchored patterns such as `/root.txt` and `doc/*.md`
- directory-only patterns such as `build/`
- `*`, `?`, character classes and `**`

Patterns are matched against paths relative to the scan root. A `.gitignore`
inside a subdirectory applies only below that directory, and its rules override
rules from parent directories. If a directory itself is ignored, it is pruned,
so negated patterns cannot re-include files inside it (matching git).

Use `--no-gitignore` to disable `.gitignore` handling:

```sh
kazu --no-gitignore .
```

## Performance

Benchmark methodology and recorded results, including comparisons with `scc`
4.1.0, are in [BENCHMARKS.md](BENCHMARKS.md).

To compare `kazu` against `scc` and `tokei` on large repositories, run the
**Benchmark** workflow from the Actions tab. It is `workflow_dispatch`-only and
accepts a repository list (`linux`, `zig`, `go`, `rust`, `ghostty`, or any
`owner/name`), an optional ref, the number of rounds, a worker count, the Zig
version, and whether to add a combined run. The workflow shallow-clones each
repository, builds `kazu`, and runs all three tools with their default
`.gitignore` behaviour. With **combined** enabled it also scans the parent
directory of every checkout as one large tree, which approximates a monorepo
workload and exercises the walker, the worker pool, and per-directory
`.gitignore` handling at scale. The Markdown report is written to the job
summary and both the Markdown and JSON results are uploaded as an artifact.

The same driver runs locally. Pass the parent directory of the checkouts as an
extra `--repo` entry to reproduce the combined run:

```sh
python3 .github/scripts/bench.py \
  --kazu ./zig-out/bin/kazu --scc scc --tokei tokei \
  --repo "kazu=$PWD" --rounds 7 --markdown results.md

# per-repository rows plus one row that scans all checkouts at once
python3 .github/scripts/bench.py \
  --kazu ./zig-out/bin/kazu --scc scc --tokei tokei \
  --repo "linux=/srv/repos/linux" \
  --repo "zig=/srv/repos/zig" \
  --repo "all-repos=/srv/repos" \
  --rounds 7 --markdown results.md
```

## Tests

```sh
zig build test
# On Termux:
zig build test -Dtarget=aarch64-linux-musl
```

## Layout

- `src/languages.zig` - language table, extension/filename/shebang detection
- `src/count.zig` - line classification and counting
- `src/gitignore.zig` - `.gitignore` parsing and path matching
- `src/format.zig` - table, JSON, Markdown, HTML, and ZON renderers
- `src/main.zig` - CLI parsing, selective `std.Io` directory walking, and batched `std.Io` workers
- `src/root.zig` - public library module
- `.github/workflows/bench.yml` - manual `kazu` vs `scc` vs `tokei` benchmark workflow
- `.github/scripts/bench.py` - interleaved benchmark driver used by the workflow
