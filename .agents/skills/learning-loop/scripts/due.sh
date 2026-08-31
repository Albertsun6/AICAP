#!/usr/bin/env bash
# due.sh — print TODAY and list notes whose next_review <= today.
# This IS the no-app spaced-repetition scheduler scan (Phase 0).
#
# Usage:  due.sh [VAULT_DIR]
#   VAULT_DIR defaults to $LEARNING_VAULT, else ./learning-vault
#
# Output: TODAY=YYYY-MM-DD, then one "DUE\t<next_review>\toverdue=Nd\tlapses=K\t<file>" line
#         per due note (sorted most-overdue first), then a summary line.
# Fails LOUD (non-zero exit, message to stderr) on missing dir / malformed dates —
# it NEVER silently drops a note from review. (See references/scheduler.md.)
set -euo pipefail

VAULT="${1:-${LEARNING_VAULT:-./learning-vault}}"
TODAY="$(date +%F)"
echo "TODAY=$TODAY"

if [[ ! -d "$VAULT" ]]; then
  echo "ERROR: vault dir not found: $VAULT  (set \$LEARNING_VAULT or pass a path; first run? create it / start learning)" >&2
  exit 2
fi

# portable ISO-8601 (YYYY-MM-DD) -> epoch-day integer; returns non-zero on a bad date
iso_to_days() {
  local d="$1" secs
  if secs="$(date -j -f "%Y-%m-%d" "$d" "+%s" 2>/dev/null)"; then        # BSD / macOS
    :
  elif secs="$(date -d "$d" "+%s" 2>/dev/null)"; then                    # GNU / Linux
    :
  else
    return 1
  fi
  echo $(( secs / 86400 ))
}

today_days="$(iso_to_days "$TODAY")"

# strip a frontmatter scalar value: drop key, trailing comment, surrounding quotes/space
field() { # field <key> <file>
  grep -m1 -E "^$1:" "$2" 2>/dev/null \
    | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//; s/^[\"']//; s/[\"']$//" \
    || true
}

due=0; scheduled=0; bad=0
rows=""

while IFS= read -r -d '' f; do
  nr="$(field next_review "$f")"
  [[ -z "$nr" || "$nr" == "null" ]] && continue
  scheduled=$((scheduled+1))
  if ! nd="$(iso_to_days "$nr")"; then
    echo "BAD-DATE next_review='$nr' in $f" >&2
    bad=$((bad+1)); continue
  fi
  if (( nd <= today_days )); then
    overdue=$(( today_days - nd ))
    lapses="$(field lapses "$f")"; lapses="${lapses:-0}"
    rows+="$(printf 'DUE\t%s\toverdue=%sd\tlapses=%s\t%s' "$nr" "$overdue" "$lapses" "$f")"$'\n'
    due=$((due+1))
  fi
done < <(find "$VAULT" -type f -name '*.md' -print0)

# sort due rows: next_review asc (col 2), then lapses desc — most overdue / leechiest first
if [[ -n "$rows" ]]; then
  printf '%s' "$rows" | sort -t$'\t' -k2,2 -k3,3
fi

echo "---"
echo "due=$due scheduled=$scheduled bad_dates=$bad vault=$VAULT"
echo "NOTE: interleave the due queue across topics/tags before quizzing (do not block one topic) — see phases/00-resume-due.md"
if (( bad > 0 )); then
  echo "ERROR: $bad note(s) had a malformed next_review — fix them before trusting the queue (fail-loud, not silent-drop)." >&2
  exit 3
fi
