#!/usr/bin/env bash
# run-probes.sh — /project-health executable probe orchestrator (Layers 0–2).
#
# Design contract:
#   - NEVER hard-fails on a missing tool. Distinguishes THREE states per probe:
#       ran_ok  | tool_failed (installed but errored, with exit code + stderr tail)
#       | skipped (not installed, with an exact install hint).
#     A failed tool is NEVER silently downgraded to "skip" or "pass".
#   - Always-on cores need NO third-party install (only git + python3 + jq):
#       (1) churn × complexity hotspots   (git + python stdlib)
#       (2) repo governance + secret scan (pure shell + git, OpenSSF-style, fail-closed)
#   - External tools (knip/vulture/radon/jscpd/dependency-cruiser/scc/audit) run only if
#     already on PATH / node_modules/.bin, OR when --npx / --pipx is passed (marked as
#     network_code_execution in the manifest — supply-chain honesty).
#   - Output dir defaults OUTSIDE the repo so probe artifacts never pollute the scan.
#   - All tools run with (cd "$REPO" && ...) via argv arrays — safe with spaces/UTF-8 paths.
#   - Security findings (committed secrets, dep vulns) carry requires_human_confirm:true.
#
# Usage:
#   run-probes.sh [--repo DIR] [--out DIR] [--since "12 months ago"] [--npx] [--pipx]
#
# Requires: bash, git, jq, python3.  (jq is NOT a macOS stock tool — `brew install jq`.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="."
OUTDIR=""
SINCE="12 months ago"
USE_NPX=0
USE_PIPX=0
NET_EXEC=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "ERROR: --repo needs a value" >&2; exit 64; }; REPO="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || { echo "ERROR: --out needs a value" >&2; exit 64; }; OUTDIR="$2"; shift 2 ;;
    --since) [ $# -ge 2 ] || { echo "ERROR: --since needs a value" >&2; exit 64; }; SINCE="$2"; shift 2 ;;
    --npx) USE_NPX=1; shift ;;
    --pipx) USE_PIPX=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

for cmd in git jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required '$cmd' not found (need git+python3+jq)" >&2; exit 64; }
done

REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "ERROR: repo not found" >&2; exit 64; }
if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: $REPO is not a git work tree" >&2; exit 64
fi

# Default output OUTSIDE the repo (fix: in-repo artifacts polluted scc/jscpd/depcruise scans).
if [ -z "$OUTDIR" ]; then
  OUTDIR="${TMPDIR:-/tmp}/project-health-$(basename "$REPO")-$$"
else
  case "$(cd "$OUTDIR" 2>/dev/null && pwd || echo "$OUTDIR")" in
    "$REPO"|"$REPO"/*) echo "  ⚠ --out is INSIDE the repo; tool scans may pick up probe artifacts" >&2 ;;
  esac
fi
mkdir -p "$OUTDIR/raw"

SKIPS="$OUTDIR/raw/_skips.jsonl"; : > "$SKIPS"
PROBES="$OUTDIR/raw/_probes.jsonl"; : > "$PROBES"

skip() { # category tool hint
  jq -nc --arg c "$1" --arg t "$2" --arg h "$3" '{category:$c, tool:$t, hint:$h}' >> "$SKIPS"
  printf '  – skip  %-12s %-18s → %s\n' "$1" "$2" "$3"
}
add_probe() { # category json
  printf '%s\n' "$2" | jq -c --arg c "$1" '. + {category:$c}' >> "$PROBES"
}
record_failed() { # category tool rc errfile
  local t; t=$(tail -3 "$4" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
  add_probe "$1" "$(jq -nc --arg t "$2" --argjson rc "$3" --arg e "$t" '{tool:$t, state:"tool_failed", exit_code:$rc, err_tail:$e}')"
  printf '  ✗ FAIL  %-12s %-18s rc=%s (installed but errored — NOT skipped)\n' "$1" "$2" "$3"
}

# Resolve a tool to a runnable argv ARRAY (handles spaces). Sets global RUNNER[].
RUNNER=()
resolve_runner() { # toolname → 0 if runnable (RUNNER set), 1 if missing
  local t="$1"; RUNNER=()
  if [ -x "$REPO/node_modules/.bin/$t" ]; then RUNNER=("$REPO/node_modules/.bin/$t"); return 0; fi
  if command -v "$t" >/dev/null 2>&1; then RUNNER=("$t"); return 0; fi
  if [ "$USE_NPX" = "1" ] && command -v npx >/dev/null 2>&1; then RUNNER=(npx --yes "$t"); NET_EXEC=1; return 0; fi
  return 1
}

echo "project-health probes → $REPO"
echo "  out: $OUTDIR  (outside repo)"

# ---------------------------------------------------------------------------
# Stack detection via `git ls-files` (fix: bash 3.2 has no globstar; monorepos).
# ---------------------------------------------------------------------------
FILES="$OUTDIR/raw/_files.txt"
git -C "$REPO" ls-files > "$FILES" 2>/dev/null || : > "$FILES"
has() { grep -qE "$1" "$FILES"; }   # regex over tracked file paths
STACK=()
{ has '(^|/)package\.json$'; } && STACK+=("javascript")
{ has '(^|/)tsconfig.*\.json$' || has '\.tsx?$'; } && STACK+=("typescript")
{ has '\.py$' || has '(^|/)(pyproject\.toml|setup\.py|requirements.*\.txt)$'; } && STACK+=("python")
has '(^|/)go\.mod$' && STACK+=("go")
{ has '(^|/)pom\.xml$' || has '\.gradle(\.kts)?$'; } && STACK+=("java")
has '(^|/)Cargo\.toml$' && STACK+=("rust")
STACK_JSON=$(printf '%s\n' "${STACK[@]:-}" | awk 'NF' | sort -u | jq -R . | jq -sc .)
echo "  stack: $(echo "$STACK_JSON" | jq -r 'if length>0 then join(", ") else "(none detected)" end')"
in_stack() { echo "$STACK_JSON" | jq -e --arg s "$1" 'index($s)' >/dev/null 2>&1; }

# shallow clone → churn/history is incomplete (fix: over-confident L2).
SHALLOW=$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || echo "false")
[ "$SHALLOW" = "true" ] && echo "  ⚠ shallow clone — history incomplete; run: git fetch --unshallow"

# ---------------------------------------------------------------------------
# L2 — hotspots (zero install; fail must NOT read as success)
# ---------------------------------------------------------------------------
HOT="$OUTDIR/raw/hotspots.json"
python3 "$SCRIPT_DIR/churn_hotspots.py" --repo "$REPO" --since "$SINCE" --top 20 --out "$HOT" >/dev/null 2>"$OUTDIR/raw/hotspots.err"
if [ -s "$HOT" ] && jq -e '.ok == true' "$HOT" >/dev/null 2>&1; then
  add_probe "hotspots" "$(jq -c '{tool:"churn_hotspots", state:"ran_ok", raw:"raw/hotspots.json", top:(.hotspots[0:5]), window_commits:.window_commits}' "$HOT")"
  printf '  ✓ probe hotspots     churn×complexity, top: %s\n' "$(jq -r '.hotspots[0].file // "n/a"' "$HOT")"
else
  err=$(jq -r '.error // "unknown"' "$HOT" 2>/dev/null || echo "unparseable")
  add_probe "hotspots" "$(jq -nc --arg e "$err" '{tool:"churn_hotspots", state:"tool_failed", error:$e}')"
  printf '  ✗ FAIL  hotspots     churn_hotspots: %s\n' "$err"
fi

# ---------------------------------------------------------------------------
# L0 — governance + secret scan (always on, fail-closed)
# ---------------------------------------------------------------------------
exists_any() { for f in "$@"; do [ -e "$REPO/$f" ] && { echo true; return; }; done; echo false; }
ci=$( { ls "$REPO"/.github/workflows/*.y*ml >/dev/null 2>&1 || [ -e "$REPO/.gitlab-ci.yml" ] || [ -e "$REPO/.circleci/config.yml" ] || [ -e "$REPO/azure-pipelines.yml" ] || [ -e "$REPO/Jenkinsfile" ]; } && echo true || echo false )
license=$(exists_any LICENSE LICENSE.md LICENSE.txt COPYING)
security=$(exists_any SECURITY.md .github/SECURITY.md docs/SECURITY.md)
contributing=$(exists_any CONTRIBUTING.md .github/CONTRIBUTING.md)
codeowners=$(exists_any CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS)
readme=$(exists_any README.md README.rst README)
gitignore=$(exists_any .gitignore)
# true lockfile (reproducible) vs mere manifest (fix #12)
lockfile=$(exists_any package-lock.json pnpm-lock.yaml yarn.lock poetry.lock uv.lock Pipfile.lock Cargo.lock go.sum Gemfile.lock composer.lock)
manifest=$(exists_any package.json pyproject.toml requirements.txt setup.py go.mod Cargo.toml pom.xml Gemfile)
debt=$(git -C "$REPO" grep -I -nE 'TODO|FIXME|HACK|XXX' -- '*.py' '*.ts' '*.tsx' '*.js' '*.go' '*.java' '*.rs' 2>/dev/null | wc -l | tr -d ' ')
authors=$(git -C "$REPO" log --since "$SINCE" --no-merges --format='%ae' 2>/dev/null | sort -u | wc -l | tr -d ' ')

# --- secret content scan: rule name + FILE PATHS ONLY, never the secret value (fix #6) ---
SECRETS="$OUTDIR/raw/_secrets.jsonl"; : > "$SECRETS"
secret_rule() { # rulename  ERE
  local files; files=$(git -C "$REPO" grep -lI -E "$2" -- \
    ':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.min.*' 2>/dev/null \
    | grep -vE '\.(example|sample|template)$' || true)
  if [ -n "$files" ]; then
    printf '%s\n' "$files" | jq -R . | jq -sc --arg r "$1" '{rule:$r, files:.}' >> "$SECRETS"
  fi
}
secret_rule "aws_access_key_id"   'AKIA[0-9A-Z]{16}'
secret_rule "github_token"        'gh[pousr]_[A-Za-z0-9]{36,}'
secret_rule "slack_token"         'xox[baprs]-[0-9A-Za-z-]{10,}'
secret_rule "private_key_block"   '-----BEGIN [A-Z ]*PRIVATE KEY-----'
secret_rule "generic_secret_kv"   '(api[_-]?key|secret|passwd|password|access[_-]?token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{12,}'
env_committed=$(git -C "$REPO" ls-files | grep -E '(^|/)\.env($|\.)' | grep -vE '\.env\.(example|sample|template)$' | head -1)
secret_files=$(cat "$SECRETS" 2>/dev/null | jq -s '.')   # array of {rule,files} (NOT `add`, which merges objects)
secret_risk=$( { [ -n "$env_committed" ] || [ "$(echo "$secret_files" | jq 'length')" -gt 0 ]; } && echo true || echo false )

# --- branch protection: use GH default branch, not current HEAD (fix #7) ---
bp="unknown"
if command -v gh >/dev/null 2>&1; then
  meta=$( ( cd "$REPO" && gh repo view --json defaultBranchRef,nameWithOwner ) 2>/dev/null || true)
  if [ -n "$meta" ]; then
    slug=$(echo "$meta" | jq -r '.nameWithOwner // empty')
    defb=$(echo "$meta" | jq -r '.defaultBranchRef.name // empty')
    if [ -n "$slug" ] && [ -n "$defb" ]; then
      if gh api "repos/$slug/branches/$defb/protection" >/dev/null 2>&1; then bp="protected"; else bp="unprotected_or_no_admin"; fi
    fi
  fi
fi

GOV=$(jq -nc \
  --argjson ci "$ci" --argjson license "$license" --argjson security "$security" \
  --argjson contributing "$contributing" --argjson codeowners "$codeowners" \
  --argjson readme "$readme" --argjson gitignore "$gitignore" \
  --argjson lockfile "$lockfile" --argjson manifest "$manifest" \
  --argjson secret_risk "$secret_risk" --argjson secret_hits "$secret_files" \
  --arg env "$env_committed" --argjson debt "$debt" --argjson authors "$authors" --arg bp "$bp" \
  '{tool:"governance", state:"ran_ok", requires_human_confirm:$secret_risk, checks:{
      ci_present:$ci, license:$license, security_policy:$security, contributing:$contributing,
      codeowners:$codeowners, readme:$readme, gitignore:$gitignore,
      dependency_lockfile:$lockfile, dependency_manifest:$manifest,
      committed_secret_risk:$secret_risk, committed_env_file:$env, secret_hits:$secret_hits,
      debt_markers:$debt, active_authors:$authors, branch_protection:$bp }}')
add_probe "governance" "$GOV"
printf '  ✓ probe governance   license:%s security:%s ci:%s lockfile:%s authors:%s bp:%s\n' "$license" "$security" "$ci" "$lockfile" "$authors" "$bp"
[ "$secret_risk" = "true" ] && printf '  🔴 SECURITY          committed secret risk (requires_human_confirm): %s\n' "$( [ -n "$env_committed" ] && echo "$env_committed " )$(echo "$secret_files" | jq -r '[.[].rule]|join(",")')"

# ---------------------------------------------------------------------------
# L0 — dependency vulnerabilities (optional; npm audit is zero-extra-install)
# ---------------------------------------------------------------------------
if in_stack javascript && [ -f "$REPO/package-lock.json" ] && command -v npm >/dev/null 2>&1; then
  ( cd "$REPO" && npm audit --json ) > "$OUTDIR/raw/npm-audit.json" 2>"$OUTDIR/raw/npm-audit.err"
  rc=$?
  if [ -s "$OUTDIR/raw/npm-audit.json" ] && jq -e . "$OUTDIR/raw/npm-audit.json" >/dev/null 2>&1; then
    total=$(jq '.metadata.vulnerabilities.total // 0' "$OUTDIR/raw/npm-audit.json")
    add_probe "dependency_vulns" "$(jq -nc --argjson n "$total" '{tool:"npm-audit", state:"ran_ok", raw:"raw/npm-audit.json", total:$n, requires_human_confirm:($n>0)}')"
    printf '  ✓ probe dep_vulns    npm audit: %s vulnerabilities\n' "$total"
  else
    record_failed "dependency_vulns" "npm-audit" "$rc" "$OUTDIR/raw/npm-audit.err"
  fi
else
  in_stack javascript && skip "dependency_vulns" "npm-audit" "needs package-lock.json + npm"
fi
if in_stack python; then
  if command -v pip-audit >/dev/null 2>&1; then
    ( cd "$REPO" && pip-audit -f json ) > "$OUTDIR/raw/pip-audit.json" 2>"$OUTDIR/raw/pip-audit.err"; rc=$?
    if [ -s "$OUTDIR/raw/pip-audit.json" ] && jq -e . "$OUTDIR/raw/pip-audit.json" >/dev/null 2>&1; then
      n=$(jq '([.dependencies[]?.vulns[]?]|length) // 0' "$OUTDIR/raw/pip-audit.json" 2>/dev/null || true); n=${n:-0}
      add_probe "dependency_vulns" "$(jq -nc --argjson n "$n" '{tool:"pip-audit", state:"ran_ok", raw:"raw/pip-audit.json", total:$n, requires_human_confirm:($n>0)}')"
      printf '  ✓ probe dep_vulns    pip-audit: %s vulnerable deps\n' "$n"
    else
      record_failed "dependency_vulns" "pip-audit" "$rc" "$OUTDIR/raw/pip-audit.err"
    fi
  else
    skip "dependency_vulns" "pip-audit" "pipx install pip-audit  (or osv-scanner for all langs)"
  fi
fi

# ---------------------------------------------------------------------------
# L1 — dead code (cd into repo; classify ran_ok / tool_failed / skip)
# ---------------------------------------------------------------------------
if in_stack javascript || in_stack typescript; then
  if resolve_runner knip; then
    ( cd "$REPO" && "${RUNNER[@]}" --reporter json --no-exit-code ) >"$OUTDIR/raw/knip.json" 2>"$OUTDIR/raw/knip.err"; rc=$?
    if [ "$rc" = "0" ] && [ -s "$OUTDIR/raw/knip.json" ]; then
      add_probe "dead_code" "$(jq -nc '{tool:"knip", state:"ran_ok", raw:"raw/knip.json"}')"
      printf '  ✓ probe dead_code    knip (JS/TS)\n'
    else
      record_failed "dead_code" "knip" "$rc" "$OUTDIR/raw/knip.err"
    fi
  else
    skip "dead_code" "knip" "npm i -D knip  (or pass --npx)"
  fi
fi
if in_stack python; then
  if resolve_runner vulture; then
    ( cd "$REPO" && "${RUNNER[@]}" . --min-confidence 80 ) >"$OUTDIR/raw/vulture.txt" 2>"$OUTDIR/raw/vulture.err"; rc=$?
    # vulture exits 1 when it FINDS dead code — that's a successful run, not a failure
    if [ "$rc" = "0" ] || [ "$rc" = "1" ] || [ "$rc" = "3" ]; then
      n=$(grep -cE 'unused' "$OUTDIR/raw/vulture.txt" 2>/dev/null || true); n=${n:-0}
      add_probe "dead_code" "$(jq -nc --argjson n "$n" '{tool:"vulture", state:"ran_ok", raw:"raw/vulture.txt", unused_findings:$n}')"
      printf '  ✓ probe dead_code    vulture (Python): %s findings\n' "$n"
    else
      record_failed "dead_code" "vulture" "$rc" "$OUTDIR/raw/vulture.err"
    fi
  elif [ "$USE_PIPX" = "1" ] && command -v pipx >/dev/null 2>&1; then
    ( cd "$REPO" && pipx run vulture . --min-confidence 80 ) >"$OUTDIR/raw/vulture.txt" 2>"$OUTDIR/raw/vulture.err"; rc=$?; NET_EXEC=1
    if [ "$rc" = "0" ] || [ "$rc" = "1" ] || [ "$rc" = "3" ]; then
      add_probe "dead_code" "$(jq -nc '{tool:"vulture", state:"ran_ok", raw:"raw/vulture.txt", via:"pipx"}')"
      printf '  ✓ probe dead_code    vulture via pipx (Python)\n'
    else
      record_failed "dead_code" "vulture" "$rc" "$OUTDIR/raw/vulture.err"
    fi
  else
    skip "dead_code" "vulture" "pipx install vulture  (or pip install vulture; or --pipx)"
  fi
fi

# ---------------------------------------------------------------------------
# L1 — complexity / size (exclude .git so artifacts don't skew LOC)
# ---------------------------------------------------------------------------
if command -v scc >/dev/null 2>&1; then
  ( cd "$REPO" && scc --format json --exclude-dir .git,node_modules,.project-health . ) >"$OUTDIR/raw/scc.json" 2>"$OUTDIR/raw/scc.err"; rc=$?
  if [ "$rc" = "0" ]; then
    add_probe "complexity" "$(jq -nc '{tool:"scc", state:"ran_ok", raw:"raw/scc.json"}')"
    printf '  ✓ probe complexity   scc (LOC/complexity, all langs)\n'
  else record_failed "complexity" "scc" "$rc" "$OUTDIR/raw/scc.err"; fi
elif command -v tokei >/dev/null 2>&1; then
  ( cd "$REPO" && tokei --output json ) >"$OUTDIR/raw/tokei.json" 2>"$OUTDIR/raw/tokei.err"; rc=$?
  [ "$rc" = "0" ] && { add_probe "complexity" "$(jq -nc '{tool:"tokei", state:"ran_ok", raw:"raw/tokei.json"}')"; printf '  ✓ probe complexity   tokei (LOC)\n'; } || record_failed "complexity" "tokei" "$rc" "$OUTDIR/raw/tokei.err"
else
  skip "complexity" "scc" "brew install scc  (LOC + cyclomatic + DRYness, all languages)"
fi
if in_stack python; then
  if command -v radon >/dev/null 2>&1; then
    ( cd "$REPO" && radon cc . -s -j ) >"$OUTDIR/raw/radon_cc.json" 2>"$OUTDIR/raw/radon_cc.err"; rc=$?
    ( cd "$REPO" && radon mi . -j ) >"$OUTDIR/raw/radon_mi.json" 2>/dev/null || true
    if jq -e . "$OUTDIR/raw/radon_cc.json" >/dev/null 2>&1; then
      add_probe "complexity" "$(jq -nc '{tool:"radon", state:"ran_ok", raw:["raw/radon_cc.json","raw/radon_mi.json"], metrics:["cyclomatic","maintainability_index"]}')"
      printf '  ✓ probe complexity   radon (Python CC + MI)\n'
    else
      record_failed "complexity" "radon" "$rc" "$OUTDIR/raw/radon_cc.err"
    fi
  else
    skip "complexity" "radon" "pipx install radon  (Python cyclomatic + Maintainability Index)"
  fi
fi

# ---------------------------------------------------------------------------
# L1 — duplication
# ---------------------------------------------------------------------------
if resolve_runner jscpd; then
  # jscpd/cpd 5.x uses --ignore-pattern (not --ignore) and respects .gitignore by default.
  ( cd "$REPO" && "${RUNNER[@]}" . --silent --reporters json --ignore-pattern '**/node_modules/**,**/.git/**,**/.project-health/**' --output "$OUTDIR/raw/jscpd" ) >/dev/null 2>"$OUTDIR/raw/jscpd.err"; rc=$?
  if [ -f "$OUTDIR/raw/jscpd/jscpd-report.json" ]; then
    pct=$(jq -r '.statistics.total.percentage // "n/a"' "$OUTDIR/raw/jscpd/jscpd-report.json" 2>/dev/null)
    add_probe "duplication" "$(jq -nc --arg p "$pct" '{tool:"jscpd", state:"ran_ok", raw:"raw/jscpd/jscpd-report.json", duplication_pct:$p}')"
    printf '  ✓ probe duplication  jscpd: %s%% duplicated\n' "$pct"
  else record_failed "duplication" "jscpd" "$rc" "$OUTDIR/raw/jscpd.err"; fi
else
  skip "duplication" "jscpd" "npm i -g jscpd  (or pass --npx; 150+ languages)"
fi

# ---------------------------------------------------------------------------
# L1 — architecture (fitness functions)
# ---------------------------------------------------------------------------
if in_stack javascript || in_stack typescript; then
  if resolve_runner depcruise; then
    tgt="."; [ -d "$REPO/src" ] && tgt="src"
    # Generate a config that actually enables no-circular/no-orphans — without rules,
    # --no-config reports 0 violations and the number is meaningless (fix #6, review-2).
    DCCFG="$OUTDIR/raw/depcruise-config.json"
    printf '%s\n' '{ "forbidden": [' \
      '  { "name": "no-circular", "severity": "error", "from": {}, "to": { "circular": true } },' \
      '  { "name": "no-orphans", "severity": "warn", "from": { "orphan": true, "pathNot": "[.]d[.]ts$" }, "to": {} }' \
      '] }' > "$DCCFG"
    ( cd "$REPO" && "${RUNNER[@]}" "$tgt" --config "$DCCFG" --output-type json ) >"$OUTDIR/raw/depcruise.json" 2>"$OUTDIR/raw/depcruise.err"; rc=$?
    if [ -s "$OUTDIR/raw/depcruise.json" ] && jq -e . "$OUTDIR/raw/depcruise.json" >/dev/null 2>&1; then
      circ=$(jq '[.summary.violations[]?|select(.rule.name=="no-circular")]|length' "$OUTDIR/raw/depcruise.json" 2>/dev/null || echo null)
      orph=$(jq '[.summary.violations[]?|select(.rule.name=="no-orphans")]|length' "$OUTDIR/raw/depcruise.json" 2>/dev/null || echo null)
      add_probe "architecture" "$(jq -nc --argjson c "${circ:-null}" --argjson o "${orph:-null}" '{tool:"dependency-cruiser", state:"ran_ok", raw:"raw/depcruise.json", circular_violations:$c, orphan_violations:$o, note:"ran with a generated no-circular/no-orphans config; persist a .dependency-cruiser.js + gate in CI"}')"
      printf '  ✓ probe architecture dependency-cruiser: %s circular, %s orphans\n' "${circ:-?}" "${orph:-?}"
    else record_failed "architecture" "dependency-cruiser" "$rc" "$OUTDIR/raw/depcruise.err"; fi
  else
    skip "architecture" "dependency-cruiser" "npm i -D dependency-cruiser  (or --npx; no-circular/no-orphans + instability)"
  fi
fi
if in_stack python; then
  if command -v lint-imports >/dev/null 2>&1; then
    add_probe "architecture" "$(jq -nc '{tool:"import-linter", state:"ran_ok", note:"import-linter present — define layered contracts in .importlinter then run lint-imports in CI"}')"
    printf '  i probe architecture import-linter present (needs .importlinter contracts)\n'
  else
    skip "architecture" "import-linter" "pipx install import-linter  (Python layered-architecture contracts)"
  fi
fi

# ---------------------------------------------------------------------------
# Assemble manifest
# ---------------------------------------------------------------------------
MANIFEST="$OUTDIR/probes.json"
jq -n \
  --arg repo "$REPO" --arg since "$SINCE" \
  --argjson stack "$STACK_JSON" \
  --argjson shallow "$([ "$SHALLOW" = "true" ] && echo true || echo false)" \
  --argjson net "$([ "$NET_EXEC" = "1" ] && echo true || echo false)" \
  --slurpfile probes "$PROBES" \
  --slurpfile skips "$SKIPS" \
  '{
     skill:"project-health", layer:"L0-L2 executable probes",
     repo:$repo, since:$since, stack:$stack,
     history_incomplete:$shallow, network_code_execution:$net,
     probes:$probes, skipped:$skips,
     states:{ran_ok:[$probes[]|select(.state=="ran_ok")|.tool], tool_failed:[$probes[]|select(.state=="tool_failed")|.tool]},
     hint:"feed probes.json + raw/* into phases/99; security items with requires_human_confirm=true are fail-closed (need human); L3 semantic review is a separate AI step"
   }' > "$MANIFEST"

echo
echo "manifest: $MANIFEST"
echo "ran_ok: $(jq '[.probes[]|select(.state=="ran_ok")]|length' "$MANIFEST")  tool_failed: $(jq '[.probes[]|select(.state=="tool_failed")]|length' "$MANIFEST")  skipped: $(jq '.skipped|length' "$MANIFEST")"
[ "$(jq '[.probes[]|select(.requires_human_confirm==true)]|length' "$MANIFEST")" -gt 0 ] && echo "🔴 requires_human_confirm: $(jq -c '[.probes[]|select(.requires_human_confirm==true)|.tool]' "$MANIFEST")"
echo "next: L3 semantic review (prompts/L3-semantic-review.txt) — probes can't judge architecture/dir-structure 'sense'"
exit 0
