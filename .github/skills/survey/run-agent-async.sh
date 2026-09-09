#!/usr/bin/env bash
# /survey — 异构 lens 长任务异步 job 机制（start / status / wait 三段式），按族路由到通道
#
# 为什么要有这个文件：Claude Code Bash 工具单次调用硬上限 600s 且不可调
# （BASH_MAX_TIMEOUT_MS 有已知 bug 不生效，issue #34138/#25881 均 not planned），
# 同步 570s watchdog 因此被钉死。但 Phase 6 全文评审（xhigh 常要 4-15 分钟）、
# Phase 2 X1 搜索（codex high 档实测 302-491s，贴着窗口）这类活同步窗口装不下，
# 超时=白烧配额+整段丢失（实测踩过）。
# 解法：nohup 把任务脱离 Claude Code 进程树，deadline 想设多长设多长；
# 主 Claude 用**有界 wait 波次**（每波 <570s，可反复续杯）拿完成通知，期间照常干别的活。
#
# 通道路由（2026-09-09 起 gpt 族在 cursor 退役）：
#   codex          → run-codex.sh          （X1 搜索眼 + Phase 6 主评审 R1/R2/R3）
#   gemini | grok  → run-cursor-agent.sh   （X2 / 红队 / tiebreaker / 替补）
#   gpt            → exit 64（已退役，改用 codex）
#
# 用法：
#   bash run-agent-async.sh start <prompt-file> <output-file> <codex|gemini|grok> [deadline-sec]
#       → stdout 打 JOB_DIR 路径后立即返回。deadline 默认 1800s（30 min），上限 7200
#   bash run-agent-async.sh status <job-dir>
#       → 一行状态：RUNNING <已跑>s/<deadline>s | DONE | FAILED exit=<N>（附 log 尾部）| DIED
#       exit code：0=DONE  3=RUNNING  4=FAILED/DIED
#   bash run-agent-async.sh wait <job-dir> [max-wait-sec]
#       → 阻塞直到 job 结束或 max-wait 到点（默认 540，**必须 <570** 以适配 Bash 工具窗口）。
#       exit code 同 status（到点仍在跑 → 3，主 Claude 再发一波 wait 续杯）
#   环境变量原样透传给 runner：SURVEY_CODEX_EFFORT / SURVEY_CURSOR_EFFORT / SURVEY_*_MODEL /
#   SURVEY_REQUIRE_SECTIONS（推荐在 start 时就设，让缺段在 job 内按 66 判掉）
#
# 主 Claude 的标准用法（⑥.5 后台长任务纪律）：
#   1. start 拿到 JOB_DIR，**当场向用户说明**：预计多久、多久查一次、超时怎么办
#   2. Bash(run_in_background:true) 跑 `wait <job-dir>`——完成时 harness 自动通知
#   3. wait 返回 3（波次到点未完）→ 报一次进度（status 的 RUNNING 行）→ 再发下一波 wait
#   4. DONE → Read <output-file>；FAILED/DIED → 按 runner 的 exit code 映射降级
#      （124=超时 / 65=调用失败 / 66=空输出或缺段 / 67=认证 / 68=配额），fail-loud
#
# job 目录布局（mktemp 私有目录，OS 定期清 /tmp）：
#   job.meta  启动参数与时间戳    job.pid   nohup 进程 pid
#   job.log   runner 的 stdout+stderr（MODEL:/OK:/ERROR: 行都在这）
#   job.exit  结束后写入 exit code（此文件存在 = job 已结束）
#   输出本体在 start 时传入的 <output-file>，不在 job 目录里

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"

CMD="${1:-}"
case "$CMD" in start|status|wait) ;; *)
  echo "Usage: $0 start <prompt-file> <output-file> <codex|gemini|grok> [deadline-sec]" >&2
  echo "       $0 status <job-dir>" >&2
  echo "       $0 wait <job-dir> [max-wait-sec]" >&2
  exit 64
esac
shift

now() { date +%s; }

# ── start ────────────────────────────────────────────────────────────────
if [ "$CMD" = start ]; then
  if [ $# -lt 3 ] || [ $# -gt 4 ]; then echo "ERROR: start 需要 3-4 个参数（族必须显式给：codex|gemini|grok）" >&2; exit 64; fi
  PROMPT_FILE="$1"; OUTPUT_FILE="$2"; FAMILY="$3"; DEADLINE="${4:-1800}"
  case "$FAMILY" in
    codex)       RUNNER="$SKILL_DIR/run-codex.sh" ;;
    gemini|grok) RUNNER="$SKILL_DIR/run-cursor-agent.sh" ;;
    gpt) echo "ERROR: gpt 族在 cursor 通道已退役（OpenAI 2026-11-12 起切断 Cursor 模型访问），改用 codex" >&2; exit 64 ;;
    *)   echo "ERROR: 未知族 '$FAMILY'（可选 codex | gemini | grok）" >&2; exit 64 ;;
  esac
  case "$DEADLINE" in *[!0-9]*|"") echo "ERROR: deadline 必须是秒数" >&2; exit 64 ;; esac
  [ "$DEADLINE" -gt 7200 ] && { echo "ERROR: deadline 上限 7200s" >&2; exit 64; }
  [ -f "$PROMPT_FILE" ] || { echo "ERROR: prompt file not found: $PROMPT_FILE" >&2; exit 66; }
  [ -f "$RUNNER" ] || { echo "ERROR: runner 缺失: $RUNNER" >&2; exit 65; }

  JOB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/survey-job.XXXXXX")
  {
    echo "family=$FAMILY"
    echo "runner=${RUNNER##*/}"
    echo "prompt=$PROMPT_FILE"
    echo "output=$OUTPUT_FILE"
    echo "deadline=$DEADLINE"
    echo "start_epoch=$(now)"
  } > "$JOB_DIR/job.meta"

  # nohup + disown：脱离本脚本进程树，Bash 工具窗口结束、甚至会话关闭都不影响它；
  # runner 自己的 watchdog（SURVEY_TIMEOUT_SEC=deadline）保证它绝不会永生
  nohup bash -c '
    SURVEY_TIMEOUT_SEC="$1" bash "$2" "$3" "$4" "$5" > "$6/job.log" 2>&1
    echo "$?" > "$6/job.exit"
  ' _ "$DEADLINE" "$RUNNER" "$PROMPT_FILE" "$OUTPUT_FILE" "$FAMILY" "$JOB_DIR" \
    >/dev/null 2>&1 &
  echo "$!" > "$JOB_DIR/job.pid"
  disown 2>/dev/null || true

  echo "$JOB_DIR"
  exit 0
fi

# ── status / wait 公共 ───────────────────────────────────────────────────
JOB_DIR="${1:-}"
[ -d "$JOB_DIR" ] && [ -f "$JOB_DIR/job.meta" ] || { echo "ERROR: 无效 job-dir: $JOB_DIR" >&2; exit 64; }
DEADLINE=$(sed -n 's/^deadline=//p' "$JOB_DIR/job.meta")
START_EPOCH=$(sed -n 's/^start_epoch=//p' "$JOB_DIR/job.meta")
OUTPUT_FILE=$(sed -n 's/^output=//p' "$JOB_DIR/job.meta")

print_status() { # → exit 0=DONE 3=RUNNING 4=FAILED/DIED
  local pid elapsed
  elapsed=$(( $(now) - START_EPOCH ))
  if [ -f "$JOB_DIR/job.exit" ]; then
    local code; code=$(cat "$JOB_DIR/job.exit")
    if [ "$code" = "0" ] && [ -s "$OUTPUT_FILE" ]; then
      echo "DONE  耗时 ${elapsed}s  输出 $(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes → $OUTPUT_FILE  $(grep '^MODEL:' "$JOB_DIR/job.log" 2>/dev/null | head -1)"
      return 0
    fi
    echo "FAILED exit=$code 耗时 ${elapsed}s（124=超deadline / 65=调用失败 / 66=空输出或缺段 / 67=认证 / 68=配额）—— job.log 尾部："
    tail -5 "$JOB_DIR/job.log" 2>/dev/null | sed 's/^/  /'
    return 4
  fi
  pid=$(cat "$JOB_DIR/job.pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "RUNNING ${elapsed}s/${DEADLINE}s  $(sed -n 's/^family=/family=/p' "$JOB_DIR/job.meta")  $(grep '^MODEL:' "$JOB_DIR/job.log" 2>/dev/null | head -1)"
    return 3
  fi
  echo "DIED  进程消失且无 exit 记录（${elapsed}s）——按失败处理，job.log 尾部："
  tail -5 "$JOB_DIR/job.log" 2>/dev/null | sed 's/^/  /'
  return 4
}

if [ "$CMD" = status ]; then
  print_status; exit $?
fi

# ── wait：有界等待波次 ───────────────────────────────────────────────────
MAX_WAIT="${2:-540}"
case "$MAX_WAIT" in *[!0-9]*|"") echo "ERROR: max-wait 必须是秒数" >&2; exit 64 ;; esac
[ "$MAX_WAIT" -gt 560 ] && { echo "ERROR: max-wait 必须 <570（Bash 工具 600s 硬上限内）" >&2; exit 64; }

WAITED=0
while [ ! -f "$JOB_DIR/job.exit" ]; do
  pid=$(cat "$JOB_DIR/job.pid" 2>/dev/null)
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || break   # 进程没了就别干等
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    print_status; exit $?    # 到点仍在跑 → 3，主 Claude 续下一波
  fi
  sleep 5
  WAITED=$((WAITED + 5))
done
print_status; exit $?
