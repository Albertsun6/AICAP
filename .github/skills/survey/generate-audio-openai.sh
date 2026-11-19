#!/usr/bin/env bash
# generate-audio-openai.sh — OpenAI TTS fallback for /survey reports
#
# Usage: generate-audio-openai.sh [-o OUT] REPORT
#   -o OUT   custom output path (default: <REPORT>.audio.mp3)
# Requires: $OPENAI_API_KEY env var; curl + jq
# Exit codes:
#   0  — success
#   2  — usage / report not found / no OPENAI_API_KEY / invalid path
#   65 — dependency unavailable (curl/jq)
#   66 — OpenAI API call failed
#
# 仅在 generate-audio.sh 失败（非 macOS 或 say 不可用）且用户已 export OPENAI_API_KEY 时调用

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

# Reject paths with newlines (avoid surprises in downstream tools)
if [[ "$REPORT" == *$'\n'* || "$OUT_ARG" == *$'\n'* ]]; then
  echo "ERROR: path contains newline" >&2
  exit 2
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "Audio generation: skipped (OPENAI_API_KEY not set)" >&2
  exit 2
fi

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Audio generation: skipped ($cmd unavailable)" >&2
    exit 65
  fi
done

OUT="${OUT_ARG:-${REPORT}.audio.mp3}"
TMP_SCRIPT=$(mktemp /tmp/survey-narration.XXXXXX.txt)
trap 'rm -f "$TMP_SCRIPT"' EXIT

# Same narration extraction as generate-audio.sh: §推荐 整段 + §待验证风险 前 3 条
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

# OpenAI TTS API: default model gpt-4o-mini-tts (2025 high-quality low-cost), voice alloy
NARRATION=$(jq -Rs . < "$TMP_SCRIPT")

VOICE="${SURVEY_AUDIO_VOICE:-alloy}"
MODEL="${SURVEY_AUDIO_MODEL:-gpt-4o-mini-tts}"

HTTP_CODE=$(curl -s -o "$OUT" -w "%{http_code}" \
  -X POST "https://api.openai.com/v1/audio/speech" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"voice\":\"$VOICE\",\"input\":$NARRATION,\"response_format\":\"mp3\"}" \
  || echo "000")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Audio generation: failed (OpenAI API returned HTTP $HTTP_CODE)" >&2
  # Output may contain error JSON, log it
  head -c 500 "$OUT" >&2 2>/dev/null || true
  rm -f "$OUT"
  exit 66
fi

echo "Audio overview: $OUT (voice: $VOICE, model: $MODEL)"
exit 0
