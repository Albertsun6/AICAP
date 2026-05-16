#!/usr/bin/env bash
# generate-audio.sh — Audio overview generator for /survey reports (macOS `say`)
#
# Usage: generate-audio.sh [-o OUT] REPORT
#   -o OUT   custom output path (default: <REPORT>.audio.m4a)
# Env vars (optional):
#   SURVEY_AUDIO_VOICE  — override voice (default: system default)
#   SURVEY_AUDIO_RATE   — override rate WPM (default: 170)
# Exit codes:
#   0  — success
#   2  — usage / report not found / invalid path
#   65 — non-macOS or `say` unavailable (caller should try generate-audio-openai.sh)
#   66 — say failed

set -euo pipefail

OUT_ARG=""
while getopts ":o:" opt; do
  case "$opt" in
    o) OUT_ARG="$OPTARG" ;;
    \?) echo "Usage: $0 [-o OUT] REPORT" >&2; exit 2 ;;
    :) echo "Option -$OPTARG requires an argument" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

REPORT="${1:-}"
if [[ -z "$REPORT" || ! -f "$REPORT" ]]; then
  echo "Usage: $0 [-o OUT] REPORT" >&2
  exit 2
fi

# Reject paths with newlines / null bytes (avoid surprises in downstream tools)
if [[ "$REPORT" == *$'\n'* || "$OUT_ARG" == *$'\n'* ]]; then
  echo "ERROR: path contains newline" >&2
  exit 2
fi

# Platform detection
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Audio generation: skipped (not macOS, current: $(uname -s))" >&2
  exit 65
fi

if ! command -v say >/dev/null 2>&1; then
  echo "Audio generation: skipped (say command unavailable on this macOS)" >&2
  exit 65
fi

OUT="${OUT_ARG:-${REPORT}.audio.m4a}"
TMP_SCRIPT=$(mktemp /tmp/survey-narration.XXXXXX.txt)
trap 'rm -f "$TMP_SCRIPT"' EXIT

VOICE_OPT=""
[[ -n "${SURVEY_AUDIO_VOICE:-}" ]] && VOICE_OPT="-v $SURVEY_AUDIO_VOICE"
RATE_OPT="-r ${SURVEY_AUDIO_RATE:-170}"

# Extract narration: §推荐 整段 + §待验证风险 前 3 条
# Strategy: capture inside the two H2 sections; strip markdown formatting.
# Fallback: if §推荐 yields nothing (old / non-template report), use first ~2000 chars of report.
CORE=$(awk '
  /^## / {
    if ($0 ~ /^## 推荐/) { mode="rec"; next }
    if ($0 ~ /^## 待验证风险/) { mode="risk"; risk_n=0; next }
    mode=""; next
  }
  mode=="rec" { print }
  mode=="risk" {
    if (risk_n < 3 && $0 ~ /^[[:space:]]*-/) { print; risk_n++ }
  }
' "$REPORT" \
  | sed -E '
      s/\*\*([^*]+)\*\*/\1/g
      s/\*([^*]+)\*/\1/g
      s/\[([^]]+)\]\([^)]+\)/\1/g
      s/`([^`]+)`/\1/g
      s/^[[:space:]]*[-*+>]+[[:space:]]*//
      s/^#+[[:space:]]+//
      /^[[:space:]]*$/d
    ' \
  | awk 'NR<=100')

if [[ -z "${CORE// }" ]]; then
  # Fallback: §推荐 not found; read first ~2000 chars of report, strip markdown
  CORE=$(head -c 2000 "$REPORT" \
    | sed -E '
        s/\*\*([^*]+)\*\*/\1/g
        s/\*([^*]+)\*/\1/g
        s/\[([^]]+)\]\([^)]+\)/\1/g
        s/`([^`]+)`/\1/g
        s/^[[:space:]]*[-*+>]+[[:space:]]*//
        s/^#+[[:space:]]+//
        /^[[:space:]]*$/d
      ')
fi

{
  echo "调研报告：$(basename "$REPORT" .md)"
  echo ""
  echo "$CORE"
  echo ""
  echo "完整报告见 $REPORT"
} > "$TMP_SCRIPT"

# Run say — m4a/aac for cross-device playback (AirDrop → iPhone Files app)
if ! say $VOICE_OPT $RATE_OPT --data-format=aac --file-format=m4af -o "$OUT" -f "$TMP_SCRIPT" 2>&1; then
  echo "Audio generation: failed (say command returned non-zero)" >&2
  exit 66
fi

# Done
echo "Audio overview: $OUT"
# Duration info (afinfo is built-in on macOS)
if command -v afinfo >/dev/null 2>&1; then
  DURATION=$(afinfo "$OUT" 2>/dev/null | awk -F': ' '/estimated duration/ {print $2}' | head -1)
  [[ -n "$DURATION" ]] && echo "Duration: $DURATION"
fi
exit 0
