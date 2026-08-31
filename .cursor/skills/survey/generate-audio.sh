#!/usr/bin/env bash
# generate-audio.sh — Audio overview generator for /survey reports
#
# Engine (统一为对话播报/同款神经嗓音):
#   1) 首选 edge-tts 晓晓 —— 复用 report-to-audio/scripts/tts.py(--provider auto,
#      内部阶梯 edge-tts → OpenAI → say,绝不硬失败)。与 Stop hook tts-play.sh 同款嗓音。
#   2) 兜底 macOS `say` —— tts.py 不可用(无 python3 / 脚本缺失)时退回。
#
# Scope: 默认=概览摘要(§推荐 整段 + §待验证风险 前 3 条)。
#        加 -t NARRATION 可朗读调用方提供的完整口语稿(/survey finalize 用它生成"完整音频":
#        主 agent 按 report-to-audio 原则把全文改写成口语稿——去表格/URL、数字转口语——再传进来;
#        不做脚本级全文 strip,因为表格/链接直接念出来不可听)。
#
# Usage: generate-audio.sh [-o OUT] [-t NARRATION] REPORT
#   -o OUT        custom output path (default: <REPORT>.audio.m4a)
#   -t NARRATION  narration text file — 跳过内置摘要抽取,直接朗读该文件(REPORT 仍需存在,用于报错与日志)
# Env vars (optional):
#   SURVEY_AUDIO_VOICE  — 覆盖嗓音(tts.py 用 edge voice 名如 zh-CN-XiaoxiaoNeural;say 用 Tingting 等)
#   SURVEY_AUDIO_RATE   — 仅影响 say 兜底的语速 WPM(默认 170);edge 路径用 tts.py 默认
# Exit codes:
#   0  — success
#   2  — usage / report not found / invalid path
#   65 — 无任何可用引擎(非 macOS 且 tts.py 不可用)→ caller 可试 generate-audio-openai.sh
#   66 — 引擎存在但合成失败

set -euo pipefail

OUT_ARG=""
NARRATION_ARG=""
while getopts ":o:t:" opt; do
  case "$opt" in
    o) OUT_ARG="$OPTARG" ;;
    t) NARRATION_ARG="$OPTARG" ;;
    \?) echo "Usage: $0 [-o OUT] [-t NARRATION] REPORT" >&2; exit 2 ;;
    :) echo "Option -$OPTARG requires an argument" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

REPORT="${1:-}"
if [[ -z "$REPORT" || ! -f "$REPORT" ]]; then
  echo "Usage: $0 [-o OUT] [-t NARRATION] REPORT" >&2
  exit 2
fi
if [[ -n "$NARRATION_ARG" && ! -f "$NARRATION_ARG" ]]; then
  echo "ERROR: narration file not found: $NARRATION_ARG" >&2
  exit 2
fi

# Reject paths with newlines / null bytes (avoid surprises in downstream tools)
if [[ "$REPORT" == *$'\n'* || "$OUT_ARG" == *$'\n'* || "$NARRATION_ARG" == *$'\n'* ]]; then
  echo "ERROR: path contains newline" >&2
  exit 2
fi

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TTS_PY="$CONFIG_DIR/skills/report-to-audio/scripts/tts.py"

OUT="${OUT_ARG:-${REPORT}.audio.m4a}"
TMP_SCRIPT=$(mktemp /tmp/survey-narration.XXXXXX.txt)
trap 'rm -f "$TMP_SCRIPT"' EXIT

# -t 模式:直接朗读调用方提供的口语稿,跳过内置摘要抽取
if [[ -n "$NARRATION_ARG" ]]; then
  cp "$NARRATION_ARG" "$TMP_SCRIPT"
else

# Extract narration: §推荐 整段 + §待验证风险 前 3 条
# - 支持带编号标题(## 七、推荐方案… / ## 八、待验证风险),不再只认精确 "## 推荐"
# - 跳过 ``` 代码块(避免把 SQL/建表语句念出来)
# - Fallback: 若 §推荐 抓不到(旧/非模板报告),用前 ~2000 字
CORE=$(awk '
  { if ($0 ~ /^[[:space:]]*```/) { infence = !infence; next } if (infence) next }
  /^## / {
    if ($0 ~ /^##[#]*[[:space:]].*推荐/)       { mode="rec";  next }
    if ($0 ~ /^##[#]*[[:space:]].*待验证风险/) { mode="risk"; risk_n=0; next }
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
      s/\[[ xX]\][[:space:]]*//
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

fi  # end of default (non -t) narration extraction

# 语言启发:含非 ASCII 字节(中日韩等)→ zh,否则 en
if LC_ALL=C grep -q '[^ -~]' "$TMP_SCRIPT"; then
  LANG_OPT="zh"
else
  LANG_OPT="en"
fi

SYNTH_OK=0
ENGINE=""

# ---- 首选:edge-tts 晓晓(tts.py --provider auto) ----
if command -v python3 >/dev/null 2>&1 && [[ -f "$TTS_PY" ]]; then
  TTS_ARGS=(--in "$TMP_SCRIPT" --out "$OUT" --lang "$LANG_OPT")
  [[ -n "${SURVEY_AUDIO_VOICE:-}" ]] && TTS_ARGS+=(--voice "$SURVEY_AUDIO_VOICE")
  if python3 "$TTS_PY" "${TTS_ARGS[@]}" 2>&1; then
    SYNTH_OK=1
    ENGINE="edge-tts/tts.py"
  fi
fi

# ---- 兜底:macOS say ----
if [[ "$SYNTH_OK" -ne 1 ]]; then
  if [[ "$(uname -s)" == "Darwin" ]] && command -v say >/dev/null 2>&1; then
    VOICE_OPT=""
    [[ -n "${SURVEY_AUDIO_VOICE:-}" ]] && VOICE_OPT="-v $SURVEY_AUDIO_VOICE"
    RATE_OPT="-r ${SURVEY_AUDIO_RATE:-170}"
    if say $VOICE_OPT $RATE_OPT --data-format=aac --file-format=m4af -o "$OUT" -f "$TMP_SCRIPT" 2>&1; then
      SYNTH_OK=1
      ENGINE="macOS say (fallback)"
    else
      echo "Audio generation: failed (say command returned non-zero)" >&2
      exit 66
    fi
  fi
fi

if [[ "$SYNTH_OK" -ne 1 ]]; then
  echo "Audio generation: skipped (no working TTS engine: tts.py unavailable and not macOS/say)" >&2
  exit 65
fi

echo "Audio overview: $OUT (engine: $ENGINE)"
if command -v afinfo >/dev/null 2>&1; then
  DURATION=$(afinfo "$OUT" 2>/dev/null | awk -F': ' '/estimated duration/ {print $2}' | head -1)
  [[ -n "$DURATION" ]] && echo "Duration: $DURATION"
fi
exit 0
