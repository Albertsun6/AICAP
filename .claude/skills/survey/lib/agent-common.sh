#!/usr/bin/env bash
# /survey — run-cursor-agent.sh 与 run-codex.sh 的**共享**底座。
# 只放"与具体 CLI 无关"的机制：watchdog / 进程树屠杀 / 额度留痕 / 结构校验 / 参数校验。
# 任何 cursor 或 codex 专有的东西都不许进来（否则两边互相拖累，又会长出 project-health
# 那种 412 行的陈旧分叉——2026-09-09 发现它超时依赖本机根本没有的 timeout 命令，等于零保护）。
#
# 供给方式：AGENT_COMMON_REQUIRE=1; . "$SKILL_DIR/lib/agent-common.sh"
# 版本护栏：调用方必须先声明 AGENT_COMMON_REQUIRE=<版本>，不匹配立即 exit 64（fail-loud，
# 防止某个镜像目录里躺着一份旧 lib 而调用方浑然不觉）。
# ⚠️ 必须由 `#!/usr/bin/env bash` 的脚本 source：run_with_deadline 依赖 `set -m`，
#    zsh 子 shell 里 `set -m` 直接报 "can't change option"（本机默认 shell 是 zsh）。
AGENT_COMMON_VERSION=1

if [ "${AGENT_COMMON_REQUIRE:-}" != "$AGENT_COMMON_VERSION" ]; then
  echo "FATAL: lib/agent-common.sh 版本不匹配（需要 ${AGENT_COMMON_REQUIRE:-<未声明>}，实际 ${AGENT_COMMON_VERSION}）" >&2
  echo "       多半是某个镜像目录里的 lib 陈旧了：比对 $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" >&2
  exit 64
fi

# ── 进程树屠杀 ──────────────────────────────────────────────────────────
# 为什么不能只用递归 pgrep，也不能只用进程组 —— 2026-09-09 本机 `ps -o pid,ppid,pgid` 实测：
#     PID   PPID  PGID  COMM
#     3296  3290  3290  node                     ← codex 的 PATH 入口是 node 脚本
#     3300  3296  3290  codex (native rust)      ← 与 node 同组
#     3858  3300  3858  codex-code-mode-host     ← **自立门户，pgid=自身 pid**
#   · 只 `kill -SIG -<job pgid>`：漏掉 3858（它已经 setpgid 跑了）
#   · 只递归 pgrep -P：能找到 3858，但与"扫描期间新生的孙进程"竞态
#   · SIGKILL 又**不可能**被 node 包装器转发（codex.js 只 forward INT/TERM/HUP），
#     漏杀 = rust 孤儿把整个模型请求跑完，继续烧订阅额度
# 所以：递归枚举后代 → 对每个后代**同时**杀它本人和它所在的进程组（去重、且绝不碰自己的组）。
_self_pgid() { ps -o pgid= -p $$ 2>/dev/null | tr -d ' '; }

collect_descendants() { # $1=pid → 深度优先输出（最深的先）
  local pid="$1" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do collect_descendants "$c"; done
  printf '%s\n' "$pid"
}

kill_tree() { # $1=信号 $2=根 pid
  local sig="$1" root="$2" p g seen=" " self
  self=$(_self_pgid)
  for p in $(collect_descendants "$root"); do
    g=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
    if [ -n "$g" ] && [ "$g" != "$self" ] && [ "$g" != "0" ]; then
      case "$seen" in
        *" $g "*) ;;
        *) seen="$seen$g "; kill "-$sig" "-$g" 2>/dev/null ;;
      esac
    fi
    kill "-$sig" "$p" 2>/dev/null
  done
}

# 带 deadline 跑命令（可移植 watchdog，**不依赖 timeout/gtimeout**——macOS 默认没有）。
# `set -m` 让后台 job 自成进程组（bash 3.2 实测有效），于是上面的组屠杀第一发就能覆盖
# node+rust 主干；自立门户的孙子由递归枚举兜住。
# 用法：run_with_deadline <秒> <stdout落盘> <stderr落盘> -- <命令...>
# 返回：124=超时；否则透传子进程退出码
run_with_deadline() {
  local deadline="$1" outf="$2" errf="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local pid t0 rc
  set -m
  "$@" >"$outf" 2>"$errf" &
  pid=$!
  set +m
  t0=$(date +%s)
  # deadline 按真实时间判断，不按 sleep 次数计数：系统睡眠/调度延迟下计数会失真
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(( $(date +%s) - t0 ))" -ge "$deadline" ]; then
      kill_tree TERM "$pid"
      sleep 2
      kill_tree KILL "$pid"       # 二次枚举：抓 TERM 宽限期内新生/漏网的进程
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.5
  done
  wait "$pid"; rc=$?
  return $rc
}

# ── 额度留痕（doctor L3.5 读它）────────────────────────────────────────
# 为什么需要它：额度耗尽对"不耗配额的快检"完全隐形（cursor `--list-models` 见底时仍 exit 0），
# 只有真调用才撞墙。撞了就写状态文件，让下一次 doctor 快检读得到。
# 行格式：<lens>\t<epoch>\t<重置日或->    lens ∈ codex / gemini / grok
SURVEY_STATE_DIR="${SURVEY_STATE_DIR:-$HOME/.cache/survey}"
QUOTA_STATE="$SURVEY_STATE_DIR/quota-state"

record_quota_block() { # $1=lens $2=错误原文
  mkdir -p "$SURVEY_STATE_DIR" 2>/dev/null || return 0
  local reset now tmp
  # cursor 文案 "...cycle ends on 1/31/2099."；codex 文案形态未实测，退而找 "resets at/on/in ..."
  reset=$(printf '%s' "$2" | sed -n 's/.*cycle ends on \([0-9][0-9/]*\).*/\1/p' | head -1)
  [ -n "$reset" ] || reset=$(printf '%s' "$2" | sed -n 's/.*[Rr]esets \(at\|on\|in\) \([^.,"]*\).*/\2/p' | head -1)
  now=$(date +%s); tmp="$QUOTA_STATE.$$"
  grep -v "^$1	" "$QUOTA_STATE" 2>/dev/null > "$tmp"
  printf '%s\t%s\t%s\n' "$1" "$now" "${reset:--}" >> "$tmp"
  mv -f "$tmp" "$QUOTA_STATE" 2>/dev/null || rm -f "$tmp"
}

clear_quota_block() { # $1=lens —— 成功调用是"该 lens 此刻可用"的直接证据，正面证据推翻负面留痕
  [ -s "$QUOTA_STATE" ] || return 0
  local tmp="$QUOTA_STATE.ok.$$"
  grep -v "^$1	" "$QUOTA_STATE" 2>/dev/null > "$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$QUOTA_STATE" 2>/dev/null || rm -f "$tmp"
  else rm -f "$tmp" "$QUOTA_STATE" 2>/dev/null; fi
}

# ── 结构校验（缺段按 exit 66 处理，见 references §调用模式第 6 步）──────
# 用法：assert_sections <文件> "## Compressed Findings" "## Source Inventory"
# 返回 0=齐全；非 0=缺段（缺的段名打到 stderr）
assert_sections() {
  local f="$1"; shift
  [ -s "$f" ] || { echo "MISSING: 输出文件为空或不存在" >&2; return 1; }
  local missing="" s
  for s in "$@"; do
    grep -qF -- "$s" "$f" || missing="$missing
  - $s"
  done
  [ -z "$missing" ] && return 0
  echo "MISSING SECTIONS:$missing" >&2
  return 1
}

# 把 SURVEY_REQUIRE_SECTIONS（`|` 分隔，段名自带空格所以**不能**按 IFS 空格分词）
# 展开成数组后跑 assert_sections。用法：check_required_sections <文件>；空变量=不校验，返回 0
check_required_sections() {
  [ -n "${SURVEY_REQUIRE_SECTIONS:-}" ] || return 0
  local req=() s old_ifs="$IFS"
  IFS='|'
  for s in ${SURVEY_REQUIRE_SECTIONS}; do [ -n "$s" ] && req+=("$s"); done
  IFS="$old_ifs"
  assert_sections "$1" "${req[@]}"
}

# ── 秒数参数校验 ────────────────────────────────────────────────────────
validate_seconds() { # $1=值 $2=下限 $3=上限 $4=回落值 $5=变量名(仅用于文案) → echo 生效值
  local v="$1" lo="$2" hi="$3" dflt="$4" name="$5"
  case "$v" in
    ''|*[!0-9]*) echo "WARN: ${name}='${v}' 非法，回落 ${dflt}" >&2; printf '%s' "$dflt"; return ;;
  esac
  if [ "$v" -lt "$lo" ] || [ "$v" -gt "$hi" ]; then
    echo "WARN: ${name}=${v} 超出 ${lo}-${hi}，回落 ${dflt}" >&2; printf '%s' "$dflt"; return
  fi
  printf '%s' "$v"
}
