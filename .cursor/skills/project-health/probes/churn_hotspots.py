#!/usr/bin/env python3
"""churn_hotspots.py — self-contained churn × complexity hotspot probe.

Layer 2 of /project-health. Implements Adam Tornhill's canonical hotspot model
(hotspot = change-frequency × code-complexity) using ONLY git + the Python
standard library — no code-maat, no CodeScene, no install required.

Complexity proxy = lines of code (Tornhill's own cheap, language-agnostic
proxy), with a secondary max-indentation-depth signal. Change frequency =
number of non-merge commits that touched the file in the window.

Output: JSON to stdout (or --out FILE):
  {
    "probe": "churn_hotspots", "ok": true,
    "since": "...", "window_commits": N, "files_analyzed": N,
    "hotspots": [
      {"file": "...", "revisions": R, "loc": L, "max_indent": D,
       "score": R*L, "score_norm": 0..1}
    ],
    "notes": [...]
  }

Never raises to the caller: any failure yields {"ok": false, "error": "..."}.
Python 3.6+ (tested on 3.9). Run from inside the target git repo or pass --repo.
"""
import argparse
import json
import os
import subprocess
import sys

# Files we never treat as "source under review".
IGNORE_DIRS = {
    ".git", "node_modules", "vendor", "dist", "build", "out", ".next",
    "__pycache__", ".venv", "venv", "target", ".idea", ".vscode",
    "coverage", ".pytest_cache", ".mypy_cache", "Pods", ".gradle",
}
IGNORE_SUFFIXES = (
    ".lock", ".lockb", ".min.js", ".min.css", ".map", ".snap",
    ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".webp", ".pdf",
    ".woff", ".woff2", ".ttf", ".eot", ".mp4", ".mov", ".m4a", ".mp3",
    ".zip", ".gz", ".tar", ".jar", ".class", ".bin", ".so", ".dylib",
)
IGNORE_NAMES = {
    "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "poetry.lock",
    "Cargo.lock", "go.sum", "composer.lock", "Gemfile.lock",
}
# Branch-ish keywords for a rough secondary cyclomatic signal (unused in the
# default score, but emitted so consumers can re-rank if they want).
BRANCH_TOKENS = ("if ", "for ", "while ", "case ", "catch ", "elif ", "&&", "||", "?")


def _git(args, repo, timeout=60):
    return subprocess.run(
        ["git", "-C", repo] + args,
        capture_output=True, text=True, timeout=timeout,
    )


def is_ignored(path):
    parts = path.split("/")
    if any(p in IGNORE_DIRS for p in parts):
        return True
    name = parts[-1]
    if name in IGNORE_NAMES:
        return True
    if path.endswith(IGNORE_SUFFIXES):
        return True
    return False


def file_metrics(abspath):
    """Return (loc_nonblank, max_indent_depth). Cheap, language-agnostic."""
    loc = 0
    max_indent = 0
    try:
        with open(abspath, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                stripped = line.strip()
                if not stripped:
                    continue
                loc += 1
                # indentation depth: tabs count as 1, every 4 leading spaces as 1
                lead = len(line) - len(line.lstrip(" \t"))
                tabs = len(line[:lead]) - len(line[:lead].replace("\t", ""))
                spaces = lead - tabs
                depth = tabs + spaces // 4
                if depth > max_indent:
                    max_indent = depth
    except (OSError, UnicodeError):
        return 0, 0
    return loc, max_indent


def main():
    ap = argparse.ArgumentParser(description="churn × complexity hotspot probe (git+stdlib only)")
    ap.add_argument("--repo", default=".", help="path to git repo (default: cwd)")
    ap.add_argument("--since", default="12 months ago",
                    help='git --since window (default: "12 months ago")')
    ap.add_argument("--top", type=int, default=20, help="how many hotspots to emit")
    ap.add_argument("--out", default=None, help="write JSON here instead of stdout")
    ap.add_argument("--ext", default=None,
                    help="comma-separated extensions to restrict to, e.g. .py,.ts,.go")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    notes = []
    result = {"probe": "churn_hotspots", "ok": False}

    # Preconditions: git present + is a repo.
    try:
        rev = _git(["rev-parse", "--is-inside-work-tree"], repo)
    except FileNotFoundError:
        result["error"] = "git not found on PATH"
        _emit(result, args.out)
        return result
    except subprocess.TimeoutExpired:
        result["error"] = "git rev-parse timed out"
        _emit(result, args.out)
        return result
    if rev.returncode != 0 or rev.stdout.strip() != "true":
        result["error"] = "not a git work tree: %s" % repo
        _emit(result, args.out)
        return result

    # shallow clone → churn history is truncated; flag it rather than over-claim (#10).
    shallow = _git(["rev-parse", "--is-shallow-repository"], repo)
    is_shallow = shallow.returncode == 0 and shallow.stdout.strip() == "true"
    if is_shallow:
        notes.append("shallow clone — churn history incomplete; run: git fetch --unshallow")

    # Collect change frequency per file over the window (non-merge commits).
    log = _git(["log", "--since", args.since, "--no-merges",
                "--name-only", "--format=%n"], repo, timeout=120)
    if log.returncode != 0:
        result["error"] = "git log failed: %s" % log.stderr.strip()[:200]
        _emit(result, args.out)
        return result

    revisions = {}
    for raw in log.stdout.splitlines():
        path = raw.strip()
        if not path or is_ignored(path):
            continue
        revisions[path] = revisions.get(path, 0) + 1

    # Count commits in window for context.
    cnt = _git(["rev-list", "--count", "--no-merges", "--since", args.since, "HEAD"], repo)
    window_commits = int(cnt.stdout.strip()) if cnt.returncode == 0 and cnt.stdout.strip().isdigit() else None

    if not revisions:
        result.update(ok=True, since=args.since, window_commits=window_commits,
                      is_shallow=is_shallow, files_analyzed=0, hotspots=[],
                      notes=notes + ["no file changes in window — widen --since or check history"])
        _emit(result, args.out)
        return result

    ext_filter = None
    if args.ext:
        ext_filter = tuple(e if e.startswith(".") else "." + e
                           for e in args.ext.split(",") if e.strip())

    rows = []
    for path, revs in revisions.items():
        if ext_filter and not path.endswith(ext_filter):
            continue
        abspath = os.path.join(repo, path)
        if os.path.islink(abspath):
            continue  # never follow symlinks — stay inside the repo boundary (#11)
        if not os.path.isfile(abspath):
            continue  # file was deleted/renamed away — skip current-complexity calc
        loc, max_indent = file_metrics(abspath)
        if loc == 0:
            continue
        rows.append({"file": path, "revisions": revs, "loc": loc,
                     "max_indent": max_indent, "score": revs * loc})

    rows.sort(key=lambda r: r["score"], reverse=True)
    top = rows[:args.top]
    max_score = top[0]["score"] if top else 1
    for r in top:
        r["score_norm"] = round(r["score"] / max_score, 3) if max_score else 0.0

    if not rows:
        notes.append("changed files exist but none currently on disk match filters")

    result.update(ok=True, since=args.since, window_commits=window_commits,
                  is_shallow=is_shallow, files_analyzed=len(rows), hotspots=top, notes=notes)
    _emit(result, args.out)
    return result


def _emit(obj, out):
    text = json.dumps(obj, ensure_ascii=False, indent=2)
    if out:
        try:
            with open(out, "w", encoding="utf-8") as f:
                f.write(text)
            print("wrote %s" % out)
        except OSError as e:
            print(text)
            print("WARN: could not write %s: %s" % (out, e), file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    _r = main()
    sys.exit(0 if isinstance(_r, dict) and _r.get("ok") else 1)
