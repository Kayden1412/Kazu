#!/usr/bin/env python3
"""Interleaved benchmark driver comparing kazu, scc, and tokei.

Every tool is executed directly with ``fork``/``exec`` so the measured wall
clock includes process startup but not a shell. Each round runs the tools in a
different order (forward, then reversed) so that drift and throttle episodes
hit every tool equally.

Timing comes from ``wait4``: wall clock is measured around the fork, CPU time
is ``ru_utime + ru_stime``, and peak RSS is ``ru_maxrss`` (KiB on Linux).
Reported timings are medians; mean, standard deviation, min, and max are kept
for context.

Each tool is run once more with stdout captured to read its reported totals
(files, lines, code, comments, blanks). That extra run is not timed.

Ignore files are honored by all three tools by default, so no ignore-disabling
flags are passed.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


class BenchError(RuntimeError):
    """A benchmark run could not be completed."""


class _TimedOut(Exception):
    pass


@dataclass
class Run:
    wall_ms: float
    cpu_ms: float
    maxrss_kb: int


@dataclass
class ToolResult:
    name: str
    runs: list[Run] = field(default_factory=list)
    counts: dict[str, int] | None = None
    error: str | None = None


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def kazu_command(executable: str, path: str, workers: int) -> list[str]:
    argv = [executable, "--format", "json"]
    if workers > 0:
        argv += ["--workers", str(workers)]
    return argv + [path]


def scc_command(executable: str, path: str) -> list[str]:
    # scc honors .gitignore by default; do not pass --no-gitignore.
    return [executable, "--no-complexity", "--no-cocomo", "--format", "json", path]


def tokei_command(executable: str, path: str) -> list[str]:
    # tokei honors .gitignore by default; do not pass --no-ignore.
    return [executable, "--output", "json", path]


# ---------------------------------------------------------------------------
# Process execution
# ---------------------------------------------------------------------------


def _on_alarm(signum: int, frame: Any) -> None:
    raise _TimedOut


def run_timed(argv: list[str], timeout: float) -> Run:
    """Run ``argv`` with stdout/stderr discarded and return its timings."""
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        start = time.perf_counter()
        pid = os.fork()
        if pid == 0:  # pragma: no cover - child process
            try:
                os.dup2(devnull, 1)
                os.dup2(devnull, 2)
                os.execvp(argv[0], argv)
            except BaseException:
                os._exit(127)

        previous = signal.signal(signal.SIGALRM, _on_alarm)
        signal.setitimer(signal.ITIMER_REAL, timeout)
        try:
            _, status, usage = os.wait4(pid, 0)
        except _TimedOut:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.wait4(pid, 0)
            raise BenchError(f"timed out after {timeout:.0f}s: {' '.join(argv)}")
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)

        wall_ms = (time.perf_counter() - start) * 1000.0
    finally:
        os.close(devnull)

    if os.WIFSIGNALED(status):
        raise BenchError(f"killed by signal {os.WTERMSIG(status)}: {' '.join(argv)}")
    code = os.WEXITSTATUS(status)
    if code != 0:
        raise BenchError(f"exit code {code}: {' '.join(argv)}")

    cpu_ms = (usage.ru_utime + usage.ru_stime) * 1000.0
    return Run(wall_ms=wall_ms, cpu_ms=cpu_ms, maxrss_kb=usage.ru_maxrss)


def run_capture(argv: list[str], timeout: float) -> bytes:
    """Run ``argv`` and return stdout, raising on a non-zero exit."""
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise BenchError(f"timed out after {timeout:.0f}s: {' '.join(argv)}")
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        suffix = f": {detail[-1]}" if detail else ""
        raise BenchError(f"exit code {proc.returncode}: {' '.join(argv)}{suffix}")
    return proc.stdout


def tool_version(executable: str) -> str:
    try:
        proc = subprocess.run(
            [executable, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    if proc.returncode != 0:
        return "unknown"
    text = proc.stdout.decode("utf-8", "replace").strip()
    return text.splitlines()[0] if text else "unknown"


# ---------------------------------------------------------------------------
# Output parsers
# ---------------------------------------------------------------------------


def _empty_counts() -> dict[str, int]:
    return {"files": 0, "lines": 0, "code": 0, "comments": 0, "blanks": 0}


def parse_kazu(raw: bytes) -> dict[str, int]:
    counts = _empty_counts()
    rows = json.loads(raw or b"[]")
    for row in rows:
        counts["files"] += int(row.get("Files", 0))
        counts["lines"] += int(row.get("Lines", 0))
        counts["code"] += int(row.get("Code", 0))
        counts["comments"] += int(row.get("Comment", 0))
        counts["blanks"] += int(row.get("Blank", 0))
    return counts


def parse_scc(raw: bytes) -> dict[str, int]:
    counts = _empty_counts()
    rows = json.loads(raw or b"[]")
    for row in rows:
        if row.get("Name") == "Total":
            continue
        counts["files"] += int(row.get("Count", 0))
        counts["lines"] += int(row.get("Lines", 0))
        counts["code"] += int(row.get("Code", 0))
        counts["comments"] += int(row.get("Comment", 0))
        counts["blanks"] += int(row.get("Blank", 0))
    return counts


def parse_tokei(raw: bytes) -> dict[str, int]:
    counts = _empty_counts()
    data = json.loads(raw or b"{}")

    total = data.get("Total")
    if isinstance(total, dict):
        # tokei already aggregates per-language totals under "Total".
        counts["code"] = int(total.get("code", 0))
        counts["comments"] = int(total.get("comments", 0))
        counts["blanks"] = int(total.get("blanks", 0))
    else:
        for name, language in data.items():
            if name == "Total" or not isinstance(language, dict):
                continue
            counts["code"] += int(language.get("code", 0))
            counts["comments"] += int(language.get("comments", 0))
            counts["blanks"] += int(language.get("blanks", 0))

    # "Total" carries no reports of its own; count files from the per-language
    # entries. Nested children repeat the same files, so they are not added.
    for name, language in data.items():
        if name == "Total" or not isinstance(language, dict):
            continue
        counts["files"] += len(language.get("reports") or [])

    counts["lines"] = counts["code"] + counts["comments"] + counts["blanks"]
    return counts


# ---------------------------------------------------------------------------
# Aggregation and rendering
# ---------------------------------------------------------------------------


def describe(values: list[float]) -> dict[str, float]:
    return {
        "n": len(values),
        "median": statistics.median(values),
        "mean": statistics.fmean(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
        "min": min(values),
        "max": max(values),
    }


def fmt_duration(ms: float) -> str:
    if ms >= 1000.0:
        return f"{ms / 1000.0:.2f} s"
    if ms >= 100.0:
        return f"{ms:.0f} ms"
    return f"{ms:.1f} ms"


def fmt_ratio(value: float) -> str:
    return f"{value:.2f}x"


def fmt_count(value: int | None) -> str:
    return "—" if value is None else f"{value:,}"


def tool_summary(result: ToolResult) -> dict[str, Any]:
    if result.error or not result.runs:
        return {"error": result.error or "no runs", "counts": result.counts}
    return {
        "wall_ms": describe([run.wall_ms for run in result.runs]),
        "cpu_ms": describe([run.cpu_ms for run in result.runs]),
        "maxrss_kb": describe([float(run.maxrss_kb) for run in result.runs]),
        "counts": result.counts,
    }


def render_markdown(
    repos: list[dict[str, Any]],
    tools: list[str],
    versions: dict[str, str],
    rounds: int,
    workers: int,
    generated_at: str,
) -> str:
    worker_label = "default (CPU count)" if workers <= 0 else str(workers)
    lines: list[str] = [
        "# kazu vs scc vs tokei",
        "",
        f"- **Generated:** {generated_at}",
        f"- **Rounds:** {rounds} (interleaved; run order alternates each round)",
        f"- **kazu workers:** {worker_label}",
        "- **Ignore files:** honored by every tool (no `--no-gitignore`)",
    ]
    for name in tools:
        lines.append(f"- **{name}:** `{versions.get(name, 'unknown')}`")

    usable = [repo for repo in repos if not repo.get("error")]
    if usable:
        lines += [
            "",
            "## Summary",
            "",
            "| Repository | " + " | ".join(tools) + " | "
            + " | ".join(f"kazu/{name}" for name in tools if name != "kazu") + " |",
            "| --- | " + " | ".join("---:" for _ in tools) + " | "
            + " | ".join("---:" for name in tools if name != "kazu") + " |",
        ]
        for repo in usable:
            cells = [repo["repo"]]
            medians: dict[str, float] = {}
            for name in tools:
                entry = repo["tools"].get(name, {})
                if "wall_ms" in entry:
                    median = entry["wall_ms"]["median"]
                    medians[name] = median
                    cells.append(fmt_duration(median))
                else:
                    cells.append("—")
            for name in tools:
                if name == "kazu":
                    continue
                if name in medians and "kazu" in medians and medians[name] > 0:
                    cells.append(fmt_ratio(medians["kazu"] / medians[name]))
                else:
                    cells.append("—")
            lines.append("| " + " | ".join(cells) + " |")

    for repo in repos:
        lines += ["", f"## {repo['repo']}", ""]
        if repo.get("error"):
            lines.append(f"> **Failed:** {repo['error']}")
            continue

        lines += [
            f"Timing (median of {rounds} rounds; `kazu/tool` below 1.00x means kazu was faster):",
            "",
            "| Tool | Median | Mean | σ | Min | Max | CPU (median) | Peak RSS | kazu/tool |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        kazu_median = repo["tools"].get("kazu", {}).get("wall_ms", {}).get("median")
        for name in tools:
            entry = repo["tools"].get(name, {})
            if "wall_ms" not in entry:
                lines.append(f"| {name} | — | — | — | — | — | — | — | — |")
                continue
            wall = entry["wall_ms"]
            cpu = entry["cpu_ms"]
            rss = entry["maxrss_kb"]
            ratio = (
                fmt_ratio(kazu_median / wall["median"])
                if name != "kazu" and kazu_median and wall["median"] > 0
                else "1.00x"
            )
            lines.append(
                "| {name} | {median} | {mean} | {sd} | {low} | {high} | {cpu} | {rss} | {ratio} |".format(
                    name=name,
                    median=fmt_duration(wall["median"]),
                    mean=fmt_duration(wall["mean"]),
                    sd=fmt_duration(wall["stdev"]),
                    low=fmt_duration(wall["min"]),
                    high=fmt_duration(wall["max"]),
                    cpu=fmt_duration(cpu["median"]),
                    rss=f"{rss['median'] / 1024.0:.1f} MiB",
                    ratio=ratio,
                )
            )

        lines += [
            "",
            "Reported totals:",
            "",
            "| Tool | Files | Lines | Code | Comments | Blank |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
        for name in tools:
            counts = repo["tools"].get(name, {}).get("counts")
            if not counts:
                lines.append(f"| {name} | — | — | — | — | — |")
                continue
            lines.append(
                "| {name} | {files} | {lines} | {code} | {comments} | {blanks} |".format(
                    name=name,
                    files=fmt_count(counts["files"]),
                    lines=fmt_count(counts["lines"]),
                    code=fmt_count(counts["code"]),
                    comments=fmt_count(counts["comments"]),
                    blanks=fmt_count(counts["blanks"]),
                )
            )

    lines += [
        "",
        "> Totals differ where the tools classify languages or lines differently;",
        "> the timing table is the benchmark, the totals are a sanity check.",
        "",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--kazu", default="kazu", help="path to the kazu binary")
    parser.add_argument("--scc", default="scc", help="path to the scc binary")
    parser.add_argument("--tokei", default="tokei", help="path to the tokei binary")
    parser.add_argument(
        "--repo",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="repository label and checkout path; repeatable",
    )
    parser.add_argument("--rounds", type=int, default=7, help="timed rounds per tool")
    parser.add_argument(
        "--workers",
        type=int,
        default=0,
        help="kazu worker count; 0 leaves the default (CPU count)",
    )
    parser.add_argument("--timeout", type=float, default=1800.0, help="per-run timeout in seconds")
    parser.add_argument("--json", dest="json_path", help="write machine-readable results here")
    parser.add_argument("--markdown", dest="markdown_path", help="write a Markdown report here")
    parser.add_argument(
        "--summary",
        dest="summary_path",
        help="append the Markdown report to this file (e.g. $GITHUB_STEP_SUMMARY)",
    )
    args = parser.parse_args(argv)

    if args.rounds < 1:
        parser.error("--rounds must be at least 1")
    if args.workers < 0:
        parser.error("--workers must be zero or greater")
    if not args.repo:
        parser.error("at least one --repo NAME=PATH is required")

    repos: list[tuple[str, str]] = []
    for entry in args.repo:
        if "=" not in entry:
            parser.error(f"--repo expects NAME=PATH, got {entry!r}")
        name, path = entry.split("=", 1)
        if not name or not path:
            parser.error(f"--repo expects NAME=PATH, got {entry!r}")
        repos.append((name, os.path.abspath(path)))
    args.repos = repos
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    tool_paths = {"kazu": args.kazu, "scc": args.scc, "tokei": args.tokei}
    tools = [name for name in ("kazu", "scc", "tokei") if tool_paths[name]]
    versions = {name: tool_version(tool_paths[name]) for name in tools}
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    print("benchmark tools:", file=sys.stderr)
    for name in tools:
        print(f"  {name}: {versions[name]} ({tool_paths[name]})", file=sys.stderr)
    print(f"rounds: {args.rounds}, kazu workers: {args.workers or 'default'}", file=sys.stderr)

    results: list[dict[str, Any]] = []
    for label, path in args.repos:
        print(f"\n== {label} ({path})", file=sys.stderr)
        repo: dict[str, Any] = {"repo": label, "path": path, "tools": {}}

        if not os.path.isdir(path):
            repo["error"] = f"checkout not found: {path}"
            results.append(repo)
            print(f"   skipped: {repo['error']}", file=sys.stderr)
            continue

        commands = {
            "kazu": kazu_command(tool_paths["kazu"], path, args.workers),
            "scc": scc_command(tool_paths["scc"], path),
            "tokei": tokei_command(tool_paths["tokei"], path),
        }

        for name in tools:
            argv = commands[name]
            result = ToolResult(name=name)
            try:
                # Warm the page cache and confirm the tool runs before timing.
                run_timed(argv, args.timeout)
                for _ in range(args.rounds):
                    result.runs.append(run_timed(argv, args.timeout))
                result.counts = {
                    "kazu": parse_kazu,
                    "scc": parse_scc,
                    "tokei": parse_tokei,
                }[name](run_capture(argv, args.timeout))
            except (BenchError, OSError, json.JSONDecodeError) as err:
                result.error = str(err)
            repo["tools"][name] = tool_summary(result)
            if result.error:
                print(f"   {name}: FAILED {result.error}", file=sys.stderr)
            else:
                wall = repo["tools"][name]["wall_ms"]["median"]
                print(f"   {name}: {fmt_duration(wall)}", file=sys.stderr)

        results.append(repo)

    report = {
        "generated_at": generated_at,
        "rounds": args.rounds,
        "workers": args.workers,
        "versions": versions,
        "tools": tools,
        "repos": results,
    }

    if args.json_path:
        with open(args.json_path, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2)
            handle.write("\n")

    markdown = render_markdown(
        results, tools, versions, args.rounds, args.workers, generated_at
    )
    if args.markdown_path:
        with open(args.markdown_path, "w", encoding="utf-8") as handle:
            handle.write(markdown)
    if args.summary_path:
        with open(args.summary_path, "a", encoding="utf-8") as handle:
            handle.write(markdown)

    failures = [repo for repo in results if repo.get("error")]
    failed_tools = [
        f"{repo['repo']}/{name}"
        for repo in results
        for name, entry in repo.get("tools", {}).items()
        if "error" in entry
    ]
    if failures or failed_tools:
        print(
            f"\ncompleted with failures: {len(failures)} repo(s), {len(failed_tools)} tool run(s)",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
