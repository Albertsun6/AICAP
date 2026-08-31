#!/usr/bin/env bash
# /survey skill — cursor-agent invocation helper
#
# 在异构模式下被主 Claude 调用（异构搜索 + 终审 = 默认开启；用 --no-hetero / --no-strict
# 关闭）。用 cursor-agent (GPT-5.5-medium, plan mode) 跑一次异构 lens 搜索或终审。失败
# 时优雅退出，让主 Claude 加 banner 并降级到全 Claude 路径。
#
# 用法：
#   ./run-cursor-agent.sh <prompt-file> <output-file>
#
# 参数：
#   <prompt-file>  : 已含完整 prompt 的文件路径（含 Agent X 模板 + 研究问题 + 4
#                    类盲区清单 + 中文排除段；主 Claude 负责拼装）
#   <output-file>  : cursor-agent 输出落盘路径
#
# Exit codes：
#   0   成功，<output-file> 已写入有效内容
#   69  cursor-agent CLI 未安装（command -v 失败）—— 主 Claude 写 banner
#       "cursor-agent not found"
#   124 timeout 触发（>300s）—— **仅当系统装了 timeout 或 gtimeout 时才会发生**。
#       macOS 默认无 timeout 命令（GNU coreutils 才有），此场景下脚本裸跑 cursor-agent，
#       超时保护由调用方（主 Claude Bash 工具的 timeout 参数）兜底。
#   65  调用失败（auth / network / 其他）—— 主 Claude 写 banner "cursor-agent error"
#   66  输出为空—— 主 Claude 写 banner "cursor-agent returned empty output"
#
# 注意：本脚本**不做** preflight 脱敏检查；survey 通用 skill 假设用户对调研内容外发
# OK。如调研内容涉敏，用户应手动 sanitize prompt 或加 --no-hetero 关闭异构。

set -uo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <prompt-file> <output-file>" >&2
  exit 64
fi

PROMPT_FILE="$1"
OUTPUT_FILE="$2"

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 66
fi

if ! command -v cursor-agent >/dev/null 2>&1; then
  echo "ERROR: cursor-agent not in PATH" >&2
  echo "Install: open Cursor → Settings → CLI tools (or cursor.com/cli)" >&2
  exit 69
fi

# 300s timeout（plan + 4 类盲区 + 5 source 要求，实测可能 2-4 min）
TIMEOUT_SEC=300

# 探测可用的 timeout 命令——macOS 默认无 `timeout`（GNU coreutils 才有），Homebrew 装为
# `gtimeout`。两个都没装时裸跑，靠主 Claude Bash 工具的 timeout 兜底。
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# 调用 cursor-agent
# 注意：用 "$(cat "$PROMPT_FILE")" 把 prompt 作为单一 argv 传入；超大 prompt 可能
# 触发 ARG_MAX，必要时未来改成 stdin
if [ -n "$TIMEOUT_BIN" ]; then
  "$TIMEOUT_BIN" "$TIMEOUT_SEC" cursor-agent \
    --print \
    --model gpt-5.5-medium \
    --output-format text \
    --sandbox enabled \
    --force \
    "$(cat "$PROMPT_FILE")" \
    > "$OUTPUT_FILE" 2>/tmp/survey-cursor-agent-stderr.log
else
  cursor-agent \
    --print \
    --model gpt-5.5-medium \
    --output-format text \
    --sandbox enabled \
    --force \
    "$(cat "$PROMPT_FILE")" \
    > "$OUTPUT_FILE" 2>/tmp/survey-cursor-agent-stderr.log
fi

EXIT=$?

if [ "$EXIT" -eq 124 ]; then
  echo "ERROR: cursor-agent timeout (>${TIMEOUT_SEC}s)" >&2
  exit 124
fi

if [ "$EXIT" -ne 0 ]; then
  echo "ERROR: cursor-agent exited $EXIT" >&2
  echo "stderr tail:" >&2
  tail -20 /tmp/survey-cursor-agent-stderr.log >&2 || true
  exit 65
fi

if [ ! -s "$OUTPUT_FILE" ]; then
  echo "ERROR: cursor-agent returned empty output" >&2
  exit 66
fi

echo "OK: cursor-agent wrote $(wc -c < "$OUTPUT_FILE") bytes to $OUTPUT_FILE"
exit 0
