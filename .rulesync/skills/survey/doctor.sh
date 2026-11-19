#!/usr/bin/env bash
# /survey — 异构链路自检 + 自修复（doctor）
#
# 为什么要有这个文件：异构眼的故障此前只能在正式调研跑到一半时以"降级 banner"形式暴露
# ——环境坏了（未安装/未登录/模型下架/文件缺失/权限丢失）用户要到 Phase 2 才知道。
# doctor 把这些检查前置成秒级探针，能自动修的当场修（目前：脚本执行位），不能自动修的
# 给出确切修复命令。
#
# 一条通道、三个 lens（2026-11-19 起三族都走 cursor-agent）：
#   gpt    = Phase 2 X1 搜索眼 + Phase 6 主评审      → 决定 verdict 档位
#   gemini = Phase 2 X2 搜索眼 + 事实 tiebreaker     → 决定 verdict 档位
#   grok   = Phase 6 红队第二评审 + 主评审/tiebreaker 的**替补族**，
#            它死了 survey 照跑，所以只 WARN、不改 verdict，但会在结论处明说
# codex CLI 是**可选备用通道**（与 gpt 同族）：未装/未登录只打一行 [INFO]，不影响 verdict。
#
# 用法：
#   bash doctor.sh            # 快检（秒级，不消耗任何配额）：L1 文件 + L2 cursor 安装/登录 + L3 模型解析 + L3.2 模型排名 + L3.5 额度留痕
#   bash doctor.sh --probe    # 加 L4 端到端微探针（三 lens 各实跑一次 tiny prompt，并发；
#                             # gpt/gemini 限 180s、grok 限 300s；消耗少量 Cursor 额度）
#
# Exit codes（供主 Claude / CI 判断）：
#   0  HEALTHY  — 两只搜索 lens（gpt + gemini）可用（含"发现问题但已自动修复"与纯 WARN；grok 死也算 HEALTHY）
#   1  DEGRADED — 一只搜索 lens 不可用，survey 会走 PARTIAL banner 降级
#   2  BROKEN   — 两只搜索 lens 均不可用、或关键文件缺失，survey 会退 3 Claude + SKIPPED banner
#
# 调用点：phases/02-research.md 要求主 Claude 在启动 X1/X2 前先跑一次快检。
# **doctor 结果绝不阻塞主流程**——BROKEN 也只是提前把降级告知用户，降级矩阵照常生效。

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CURSOR_RUNNER="$SKILL_DIR/run-cursor-agent.sh"
CODEX_RUNNER="$SKILL_DIR/run-codex.sh"
LIB="$SKILL_DIR/lib/agent-common.sh"

# 未知参数必须硬拒：--proeb 这类拼错若静默当快检跑，调用者会以为真探针已执行
PROBE=0
case "${1:-}" in
  "") ;;
  --probe)
    [ $# -gt 1 ] && { echo "ERROR: --probe 不接受多余参数" >&2; exit 64; }
    PROBE=1 ;;
  *) echo "ERROR: 未知参数 '${1}'（仅支持 --probe）" >&2; exit 64 ;;
esac

# lib 缺失时 doctor 自己都跑不起来——先于 L1 明说，别让 set -u 报一堆 unbound 迷惑人
if [ ! -r "$LIB" ]; then
  echo "[FAIL]  lib/agent-common.sh 缺失——run-cursor-agent.sh / run-codex.sh / doctor 全部无法运行" >&2
  echo "VERDICT: BROKEN — 到 skill 所在 git 仓库 checkout 该目录" >&2
  exit 2
fi
AGENT_COMMON_REQUIRE=1
. "$LIB"

# ── 结果记账 ─────────────────────────────────────────────────────────────
GPT_LENS=ok
GEMINI_LENS=ok
GROK_LENS=ok
CURSOR_BROKEN=0     # cursor-agent 未装/未登录 → 三族齐灭（同通道）
WARN_COUNT=0
FIX_COUNT=0
REPAIRS=""          # 攒到最后统一打印的人工修复建议（每行一条）

say()    { printf '%s\n' "$1"; }
pass()   { say "[PASS]  $1"; }
info()   { say "[INFO]  $1"; }   # 只告知、不计 WARN、不影响 verdict（备用通道状态用它）
fixed()  { say "[FIXED] $1"; FIX_COUNT=$((FIX_COUNT + 1)); }
warn()   { say "[WARN]  $1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail()   { say "[FAIL]  $1"; }
repair() { REPAIRS="${REPAIRS}  - $1
"; }

# bash 3.2 没有 nameref，用 case 分发给对应的 *_LENS 变量
set_lens() { # $1=lens $2=ok|dead
  case "$1" in
    gpt)    GPT_LENS="$2" ;;
    gemini) GEMINI_LENS="$2" ;;
    grok)   GROK_LENS="$2" ;;
  esac
}
# 某 lens 出问题时统一走这里：搜索眼（gpt/gemini）算 FAIL，替补族（grok）只算 WARN——
# 用 [FAIL] 报 grok 会让用户以为这次 survey 要降级，实际上它只是少了红队那一路
lens_bad() { # $1=lens $2=消息
  if [ "$1" = grok ]; then warn "$2 —— grok 是替补族，本次 verdict 不受影响（红队取消 + 替补链变短）"
  else fail "$2"; fi
  set_lens "$1" dead
}

# 带 deadline 跑命令：复用 lib 的可移植 watchdog。$1=秒 $2=stdout 落盘（stderr 分流到 <文件>.err
# ——不合流：晚到的 stderr 会污染"stdout 末行=模型 id"这类约定）
run_deadline() {
  local d="$1" out="$2"; shift 2
  run_with_deadline "$d" "$out" "${out}.err" -- "$@"
}

# 只影响措辞、绝不参与 verdict：区分"从没登录/凭据已被清除"与"存过凭据但已失效"。
# status 的 exit code 在已登录/已过期/未登录三态下实测恒为 0，故只取文本、忽略退出码。
auth_hint() {
  run_deadline 10 "$WORK/status.txt" cursor-agent status
  cat "$WORK/status.txt.err" >> "$WORK/status.txt" 2>/dev/null
  if grep -qiE "not logged|logged out" "$WORK/status.txt" 2>/dev/null; then
    printf '%s' "status=Not logged in：本机从未登录，或失效凭据已被 CLI 自行清除"
  elif grep -qi "logged in" "$WORK/status.txt" 2>/dev/null; then
    printf '%s' "status 自称 Logged in——只证明本机存过凭据，不证明它现在有效（典型的会话过期）"
  else
    printf '%s' "status 输出无法判读"
  fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/survey-doctor.XXXXXX")
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "ERROR: mktemp 失败（TMPDIR='${TMPDIR:-/tmp}' 可写吗？）" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
# doctor 被 kill/Ctrl+C 时联动杀掉后台探针进程树——否则 --probe 的真实模型请求会作为孤儿继续烧配额
PROBE_PIDS=""
on_signal() {
  local p
  for p in $PROBE_PIDS; do kill_tree TERM "$p"; done
  exit 130
}
trap on_signal INT TERM

# ═══ L1 文件完整性 + 执行位（本地，可自动修复）═══════════════════════════
say "── L1 文件完整性 ──"

# Read gate 依赖的全部文件 + 运行时依赖：任何一个缺失，对应 phase 会硬停（SKILL.md §模板缺失处理）
REQUIRED_FILES="SKILL.md
lib/agent-common.sh
run-cursor-agent.sh
run-codex.sh
run-agent-async.sh
check-citations.sh
phases/01-question-framing.md
phases/02-research.md
phases/03-reflection.md
phases/04-synthesis.md
phases/05-citation.md
phases/06-debate.md
prompts/brief-template.txt
prompts/agent-x.txt
prompts/agent-x2.txt
prompts/round1.txt
prompts/round1-grok-prefix.txt
prompts/round2-rebuttal.txt
prompts/tiebreak.txt
references/source-quality.md
references/cursor-agent-invocation.md"

MISSING=0
FILES_BROKEN=0
while IFS= read -r f; do
  # -f 且 -r 且 -s：macOS 上目录也能过 [ -s ]，无读权限的文件 Read gate 一样硬停
  if [ ! -f "$SKILL_DIR/$f" ] || [ ! -r "$SKILL_DIR/$f" ] || [ ! -s "$SKILL_DIR/$f" ]; then
    # ⚠️ 变量后紧跟全角字符必须用 ${} 括起：macOS 自带 bash 3.2 会把多字节字符的
    #    首字节并进变量名，set -u 下直接炸 unbound variable（实测踩过）
    fail "缺失/不可读/为空: ${f}（对应 phase 的 Read gate 会硬停）"
    MISSING=$((MISSING + 1))
  fi
done <<EOF
$REQUIRED_FILES
EOF
if [ "$MISSING" -eq 0 ]; then
  pass "$(printf '%s\n' "$REQUIRED_FILES" | wc -l | tr -d ' ') 个 Read-gate / 运行时依赖文件齐全"
else
  # 文件残缺 ≠ lens 不可用——单独记账，L2-L4 照常体检 lens，verdict 分开表述
  FILES_BROKEN=1
  repair "恢复 survey skill 文件（真实目录: $(cd "$SKILL_DIR" 2>/dev/null && pwd -P || echo "$SKILL_DIR")，到其所在 git 仓库 checkout 该目录）"
fi

# 执行位：文档统一用 `bash xxx.sh` 调用所以缺 +x 不致命，但 `./` 直调会 126
# （126 不在 exit code 降级映射表里，会被误判成未知崩溃）——这里直接修掉。
NEED_X=()
for s in "$SKILL_DIR"/*.sh "$SKILL_DIR"/lib/*.sh; do
  [ -f "$s" ] || continue
  [ -x "$s" ] || NEED_X+=("$s")
done
if [ "${#NEED_X[@]}" -gt 0 ]; then
  chmod +x "${NEED_X[@]}" 2>/dev/null
  STILL=""
  FIXED_NAMES=""
  for s in "${NEED_X[@]}"; do
    if [ -x "$s" ]; then FIXED_NAMES="$FIXED_NAMES ${s##*/}"; else STILL="$STILL ${s##*/}"; fi
  done
  [ -n "$FIXED_NAMES" ] && fixed "补上执行位:$FIXED_NAMES"
  [ -n "$STILL" ] && warn "chmod +x 失败:${STILL}（不影响文档规定的 bash 调用路径）"
else
  pass "全部 .sh 具备执行位"
fi

# L2 的登录探针会把实时模型列表落到这里，L3 直接复用做"存在性复核"（不重复请求）。
LIVE_LIST="$WORK/live-models.txt"
LIVE_OK=0

# ═══ L2a cursor-agent CLI：安装 + 登录（三族共用的唯一必需通道）═════════
say "── L2a cursor-agent CLI（gpt + gemini + grok 通道）──"

if ! command -v cursor-agent >/dev/null 2>&1; then
  fail "cursor-agent 未安装——gpt / gemini 搜索眼 + grok 替补族均不可用"
  repair "安装 cursor-agent: curl https://cursor.com/install -fsS | bash（或 Cursor → Settings → CLI tools）"
  CURSOR_BROKEN=1
else
  VER=$(run_deadline 10 "$WORK/ver.txt" cursor-agent --version >/dev/null 2>&1; cat "$WORK/ver.txt" "$WORK/ver.txt.err" 2>/dev/null | head -1)
  pass "cursor-agent 已安装（${VER:-版本未知}，$(command -v cursor-agent)）"

  # ── 登录态判据：只认"服务端此刻认不认"，不认 status 的自述 ─────────────
  # 2026-08-30 实测：session JWT 过期 4 天时 `cursor-agent status` 仍 exit 0 并打印
  # "Logged in (unable to fetch user details)"；旧判据据此报 HEALTHY，而每一次真调用都必挂。
  # --list-models 是唯一"真打服务端又不做任何模型推理"的命令（不烧配额），
  # 成功时列表直接交给 L3 复核存在性。
  run_deadline 25 "$LIVE_LIST" cursor-agent --list-models
  LM_EXIT=$?
  LM_ERR="${LIVE_LIST}.err"

  if [ "$LM_EXIT" -eq 0 ] && [ -s "$LIVE_LIST" ]; then
    LIVE_OK=1
    pass "已登录，且凭据被服务端接受（--list-models 返回 $(grep -cve '^[[:space:]]*$' "$LIVE_LIST") 行）"
  elif grep -qiE "authentication required|authentication failed|stored authentication is invalid|invalid or expired|unauthoriz|forbidden" "$LM_ERR" 2>/dev/null; then
    fail "cursor 凭据不可用——gpt / gemini / grok 均不可用（$(auth_hint)）"
    # **不推荐**为省这一步去造长期 CURSOR_API_KEY：它不换计费池、解决不了额度问题，
    # 却把一枚长期凭据从 Keychain 挪到明文环境变量
    repair "重新登录 Cursor: cursor-agent login（会话硬 60 天上限、不可续期，到期需重登）"
    CURSOR_BROKEN=1
  elif [ "$LM_EXIT" -eq 124 ] || grep -qiE "failed to load models|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|socket hang up|fetch failed|network|proxy|tls|certificate" "$LM_ERR" 2>/dev/null; then
    # 连不上 != 未登录：把网络抖动误报成未登录，会让用户白跑一次浏览器 login
    warn "连不上 Cursor 服务（$([ "$LM_EXIT" -eq 124 ] && printf '>25s 超时' || printf 'exit %s' "$LM_EXIT")）——登录态无法验证，正式调用可能失败"
    repair "检查网络/代理后重试: cursor-agent --list-models"
  else
    # 没见过的失败形态：fail-closed。静默放行正是本 skill 一直在防的东西
    fail "cursor-agent --list-models 以未识别的方式失败（exit ${LM_EXIT}）——按不可用处理"
    say "        stderr 首行：$(head -1 "$LM_ERR" 2>/dev/null)"
    repair "手动确认: cursor-agent --list-models；必要时 cursor-agent login"
    CURSOR_BROKEN=1
  fi
fi

# ═══ L2b codex CLI：可选备用通道（只告知，不影响 verdict）═══════════════
say "── L2b codex CLI（可选备用通道，与 gpt 同族）──"

if ! command -v codex >/dev/null 2>&1; then
  info "codex 未安装——备用通道不可用（不影响 verdict；默认流程三族都走 cursor）"
else
  # 认证判据由 run-codex.sh --auth-check 实打服务端（零配额）。**不用** `codex login status`
  # （伪造凭据下照样打印 "Logged in using ChatGPT"）也不用 `codex doctor` 的 auth.credentials
  # （签名改坏仍报 ok/exit 0）——两者都是"磁盘上有没有 token"的自述，与 cursor status 是同一个坑
  run_deadline 40 "$WORK/codex-auth.txt" bash "$CODEX_RUNNER" --auth-check
  CA_EXIT=$?
  CA_LINE=$(grep '^AUTH:' "$WORK/codex-auth.txt.err" 2>/dev/null | tail -1)
  if [ "$CA_EXIT" -eq 0 ]; then
    info "codex 备用通道可用（${CA_LINE#AUTH: }）"
  else
    info "codex 未登录或认证无法验证（exit ${CA_EXIT}）——备用通道不可用（不影响 verdict；要启用再自行 codex login）"
  fi
fi

# ═══ L3 各 lens 模型解析（复用生产逻辑 --resolve-only，不消耗配额）════════
say "── L3 模型解析（gpt 搜索眼 / gemini 搜索眼 / grok 替补族）──"

if [ "$CURSOR_BROKEN" -eq 0 ]; then
  [ "$LIVE_OK" -eq 1 ] || warn "实时模型列表取不到——cursor 侧解析结果无法复核存在性"
  for FAM in gpt gemini grok; do
    if run_deadline 40 "$WORK/resolve-$FAM.txt" bash "$CURSOR_RUNNER" --resolve-only "$FAM"; then
      MODEL_ID=$(tail -1 "$WORK/resolve-$FAM.txt")
      # 空串/非法字符 = 解析隐式崩溃，fail-closed，绝不当合法 id 放行
      case "$MODEL_ID" in
        "" | *[!A-Za-z0-9._-]*)
          lens_bad "$FAM" "[$FAM] 解析返回了空或非法 id——按 lens 不可用处理"
          continue ;;
      esac
      SRC=live
      grep -qE "WARN: .*(回落到|取模型列表失败)" "$WORK/resolve-$FAM.txt.err" 2>/dev/null && SRC=fallback
      [ -n "${SURVEY_CURSOR_MODEL:-}" ] && [ "$MODEL_ID" = "$SURVEY_CURSOR_MODEL" ] && SRC=pinned
      # 首列精确等值匹配，不用 grep 正则：id 里的 . 会被当通配符
      if [ "$LIVE_OK" -eq 1 ] && ! awk -v id="$MODEL_ID" '$1 == id {f=1} END {exit !f}' "$LIVE_LIST"; then
        # runner 在"列表取到了但该族无候选"时会说明是缩水还是下架——缩水是临时的，别让人去改 FALLBACK
        if grep -q "疑似临时缩水" "$WORK/resolve-$FAM.txt.err" 2>/dev/null; then
          lens_bad "$FAM" "[$FAM] 模型列表疑似临时缩水（实时列表里暂时没有该族）——现在调用会 fail-closed 跳过，通常不到一小时恢复"
          repair "[$FAM] 稍后重跑 bash $SKILL_DIR/doctor.sh（列表恢复前不要改 FALLBACK_MODEL，也不要判定该族已下架）"
          continue
        fi
        lens_bad "$FAM" "[$FAM] ${SRC} 模型 ${MODEL_ID} 不在实时列表——正式调用会 fail-closed 跳过$(grep -q "可能已下架" "$WORK/resolve-$FAM.txt.err" 2>/dev/null && printf '（列表完整却没有该族候选：可能已下架或命名已变）')"
        case "$SRC" in
          pinned) repair "unset SURVEY_CURSOR_MODEL，或钉一个 cursor-agent --list-models 里存在的 id" ;;
          *)      repair "更新 run-cursor-agent.sh 中 [$FAM] 的 FALLBACK_MODEL，并跑 bash $SKILL_DIR/test-model-selection.sh 校准解析规则" ;;
        esac
        continue
      fi
      case "$SRC" in
        live)     pass "[$FAM] 解析到 $MODEL_ID" ;;
        pinned)   pass "[$FAM] 用 SURVEY_CURSOR_MODEL 钉值 ${MODEL_ID}$([ "$LIVE_OK" -eq 1 ] && printf '（已核在实时列表中）')" ;;
        fallback) warn "[$FAM] 实时解析失败，回落 ${MODEL_ID}$([ "$LIVE_OK" -eq 1 ] && printf '（仍在实时列表，正式调用应可成功）')"
                  repair "跑一遍模型选择回归并按结果更新规则: bash $SKILL_DIR/test-model-selection.sh" ;;
      esac
    else
      lens_bad "$FAM" "[$FAM] 模型解析超时/崩溃（>40s）"
    fi
  done
else
  say "（cursor 侧跳过——L2a 已判该通道不可用）"
  GPT_LENS=dead; GEMINI_LENS=dead; GROK_LENS=dead
fi

# ═══ L3.2 模型排名文件（新模型提示 + 核对日期；只 WARN，不改 verdict）════
# 选型顺序来自 model-ranking.conf（上网查证后的结论）。两种情况说明它该重查了：
#   ① runner 在实时列表里看到清单之外的模型（stderr 的 NEW-MODEL: 行；检测在选型筛选之前，
#      裸 id / -max / -preview / 认不出的命名形态也算），或排名文件自检不过（WARN: … 排名文件 …）
#   ② 核对日期超过 RANK_MAX_AGE_DAYS 天
# 都不影响 lens 可不可用，所以只报 WARN；修复动作是上网核实，doctor 不代劳。
say "── L3.2 模型排名（model-ranking.conf）──"
RANK_FILE="${SURVEY_RANKING_FILE:-$SKILL_DIR/model-ranking.conf}"
RANK_MAX_AGE_DAYS=60
RANK_WARNS=0
# 改哪一份：本目录若是 rulesync 生成的镜像（<仓库>/.claude|.agents|.cursor|.github/skills/survey，
# ~/.claude/skills/survey 就是指向它的软链），直接改这里的文件会在下次 `pnpm run ai:generate` 时被
# .rulesync 源覆盖，核实结果就丢了——所以修复建议指向源文件，并写明要重新生成
RANK_EDIT="$RANK_FILE"; RANK_REGEN=""
if [ -z "${SURVEY_RANKING_FILE:-}" ]; then
  PHYS_DIR="$(cd "$SKILL_DIR" && pwd -P)"
  case "$PHYS_DIR" in
    */.rulesync/skills/survey) ;;
    */.*/skills/survey)
      REPO_ROOT="${PHYS_DIR%/.*/skills/survey}"
      if [ -f "$REPO_ROOT/.rulesync/skills/survey/model-ranking.conf" ]; then
        RANK_EDIT="$REPO_ROOT/.rulesync/skills/survey/model-ranking.conf"
        RANK_REGEN="；这是源文件，本目录是生成的镜像（直接改镜像会被覆盖），改完在 ${REPO_ROOT} 下跑 pnpm run ai:generate 并给镜像里的 .sh 补执行位"
      fi ;;
  esac
fi
RANK_REPAIR="上网核实后更新 model-ranking.conf 的顺序、清单和核对日期（查官方模型页、厂商发布说明、独立评测；要改的文件: ${RANK_EDIT}${RANK_REGEN}），改完跑 bash $SKILL_DIR/test-model-selection.sh"

if [ ! -r "$RANK_FILE" ]; then
  # 不并入上面 runner 的同类 WARN（每族一行，共三行说的是同一件事）
  warn "排名文件 ${RANK_FILE} 缺失或不可读——系列顺序用脚本内保底顺序，新模型检测不生效"
  repair "恢复 model-ranking.conf（到 skill 所在 git 仓库 checkout），或按文件头格式重建"
else
  for FAM in gpt gemini grok; do
    [ -s "$WORK/resolve-$FAM.txt.err" ] || continue
    while IFS= read -r NM_LINE; do
      [ -n "$NM_LINE" ] || continue
      warn "${NM_LINE}"
      RANK_WARNS=$((RANK_WARNS + 1))
    done <<EOF
$(grep -E '^NEW-MODEL: |^WARN: .*排名文件' "$WORK/resolve-$FAM.txt.err" 2>/dev/null | sort -u)
EOF
  done
  # 日期差用 awk 按儒略日算：BSD date 与 GNU date 的解析参数不通用
  STALE=$(awk -v today="$(date +%Y-%m-%d)" -v max="$RANK_MAX_AGE_DAYS" '
    function jdn(s,  a, y, m, d) {
      if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return -1
      split(s, a, "-"); y = a[1] + 0; m = a[2] + 0; d = a[3] + 0
      if (m <= 2) { y--; m += 12 }
      return int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + d - 1524
    }
    { sub(/\r$/, ""); $0 = tolower($0) }     # 与 runner 一致：键名 / 段名不分大小写
    /^[ \t]*\[/ { sec = $0; gsub(/[^a-z]/, "", sec); next }
    /^[ \t]*checked[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); c[sec] = v }
    END {
      n = split("gpt gemini grok", f, " ")
      for (i = 1; i <= n; i++) {
        if (!(f[i] in c) || jdn(c[f[i]]) < 0) out = out " " f[i] "(核对日期缺失或格式不对)"
        else if (jdn(today) - jdn(c[f[i]]) > max) out = out " " f[i] "(" c[f[i]] "，已 " jdn(today) - jdn(c[f[i]]) " 天)"
      }
      print out
    }' "$RANK_FILE")
  if [ -n "$STALE" ]; then
    warn "模型排名的核对日期超过 ${RANK_MAX_AGE_DAYS} 天:${STALE}——排名可能已过时"
    RANK_WARNS=$((RANK_WARNS + 1))
  fi
  if [ "$RANK_WARNS" -gt 0 ]; then
    repair "$RANK_REPAIR"
  elif [ "$CURSOR_BROKEN" -eq 1 ]; then
    pass "三族核对日期均在 ${RANK_MAX_AGE_DAYS} 天内（cursor 通道不通，本次没有检测新模型）"
  else
    pass "没有未核实的新模型；三族核对日期均在 ${RANK_MAX_AGE_DAYS} 天内"
  fi
fi

# ═══ L3.5 额度留痕（读真调用留下的痕迹；不真打、不耗配额）════════════════
# 为什么必须单独一层：额度耗尽对 L1-L3 完全隐形（cursor `--list-models` 见底时仍 exit 0 返回
# 完整列表）。额度只有真调用能发现，所以 runner 撞墙时写状态
# 文件，这里读它。只认 24h 内的记录（cursor 按月重置、codex 按小时/周滚动，陈旧记录会误报），
# 读到过期记录顺手删掉。
say "── L3.5 额度留痕（依据最近一次真调用）──"
QUOTA_TTL=86400

if [ ! -s "$QUOTA_STATE" ]; then
  pass "无额度告警留痕（说明最近一次真调用没撞上用量上限）"
else
  NOW=$(date +%s)
  QS_TMP="$QUOTA_STATE.doctor.$$"
  : > "$QS_TMP"
  QUOTA_HIT=0
  while IFS="$(printf '\t')" read -r Q_LENS Q_TS Q_RESET; do
    [ -n "${Q_LENS:-}" ] || continue
    case "${Q_TS:-}" in ''|*[!0-9]*) continue ;; esac      # 脏行直接丢弃
    AGE=$(( NOW - Q_TS ))
    if [ "$AGE" -ge "$QUOTA_TTL" ]; then
      continue                                             # 过期不写回 = 自清理
    fi
    printf '%s\t%s\t%s\n' "$Q_LENS" "$Q_TS" "${Q_RESET:--}" >> "$QS_TMP"
    QUOTA_HIT=1
    case "$Q_LENS" in
      gpt|gemini|grok)
        lens_bad "$Q_LENS" "[$Q_LENS] $(( AGE / 60 )) 分钟前真调用撞到 Cursor 月度额度上限——该族本月不可用（重置日 ${Q_RESET:--}）" ;;
      codex)
        info "[codex] 备用通道 $(( AGE / 60 )) 分钟前真调用撞到 ChatGPT 用量上限（${Q_RESET:--}）——不影响 verdict" ;;
      *)   warn "额度状态文件里有未知 lens '$Q_LENS'，已忽略" ;;
    esac
  done < "$QUOTA_STATE"
  mv -f "$QS_TMP" "$QUOTA_STATE" 2>/dev/null || rm -f "$QS_TMP"
  if [ "$QUOTA_HIT" -eq 1 ]; then
    repair "额度耗尽：三选一（换族／等重置日／Cursor 后台开 on-demand）；gpt 族见底时可临时启用 codex 备用通道（需自行 codex login）"
    say "        注：重置后第一次成功调用会自动清掉留痕；也可手删 $QUOTA_STATE"
  else
    pass "额度留痕均已超过 24h（视为过期，已清理）"
  fi
fi

# ═══ L4 端到端微探针（--probe 才跑；消耗少量配额）════════════════════════
if [ "$PROBE" -eq 1 ]; then
  say "── L4 端到端微探针（三 lens 并发；gpt/gemini 各限 180s、grok 限 300s）──"
  printf 'Reply with exactly this single line and nothing else: HETERO-PROBE-OK' > "$WORK/probe-prompt.txt"

  T0=$(date +%s)
  PID_GPT=""; PID_GEMINI=""; PID_GROK=""
  if [ "$CURSOR_BROKEN" -eq 0 ]; then
    # 探针统一用 high 档：验的是"生产要用的族调得通"，xhigh 只会多烧额度、多等时间
    SURVEY_CURSOR_EFFORT=high run_deadline 180 "$WORK/probe-gpt.log" bash "$CURSOR_RUNNER" "$WORK/probe-prompt.txt" "$WORK/probe-gpt.out" gpt &
    PID_GPT=$!
    SURVEY_CURSOR_EFFORT=high run_deadline 180 "$WORK/probe-gemini.log" bash "$CURSOR_RUNNER" "$WORK/probe-prompt.txt" "$WORK/probe-gemini.out" gemini &
    PID_GEMINI=$!
    # grok 单独给 300s：该族基础延迟明显高（2026-08-15 实测 263s 跑完一个 2 问 prompt）
    SURVEY_CURSOR_EFFORT=high run_deadline 300 "$WORK/probe-grok.log" bash "$CURSOR_RUNNER" "$WORK/probe-prompt.txt" "$WORK/probe-grok.out" grok &
    PID_GROK=$!
  fi
  PROBE_PIDS="$PID_GPT $PID_GEMINI $PID_GROK"
  E_GPT=-1; E_GEMINI=-1; E_GROK=-1
  [ -n "$PID_GPT" ]    && { wait "$PID_GPT";    E_GPT=$?; }
  [ -n "$PID_GEMINI" ] && { wait "$PID_GEMINI"; E_GEMINI=$?; }
  [ -n "$PID_GROK" ]   && { wait "$PID_GROK";   E_GROK=$?; }
  PROBE_PIDS=""
  EL=$(( $(date +%s) - T0 ))

  for L in gpt gemini grok; do
    case "$L" in gpt) E=$E_GPT ;; gemini) E=$E_GEMINI ;; grok) E=$E_GROK ;; esac
    if [ "$E" -eq -1 ]; then say "        [$L] 探针跳过（通道已在 L2 判死）"; continue; fi
    PROBE_MODEL=$(grep '^MODEL:' "$WORK/probe-$L.log.err" 2>/dev/null | head -1 | cut -d' ' -f2)
    # 必须核对 prompt 约定的哨兵串，不能只看"非空"：模型返回任意报错文本也非空
    if [ "$E" -eq 0 ] && grep -q "HETERO-PROBE-OK" "$WORK/probe-$L.out" 2>/dev/null; then
      pass "[$L] 端到端探针通过（${PROBE_MODEL:-模型未知}，总耗时 ${EL}s）"
      set_lens "$L" ok      # 真实调用成功是最强证据：推翻 L3 的瞬时失败标记
    elif [ "$E" -eq 0 ]; then
      lens_bad "$L" "[$L] 探针 exit 0 但输出不含 HETERO-PROBE-OK（模型输出异常，视同失败）——输出头部："
      head -2 "$WORK/probe-$L.out" 2>/dev/null | sed 's/^/        /'
    else
      lens_bad "$L" "[$L] 端到端探针失败（exit $E$([ "$E" -eq 124 ] && printf '，超时')$([ "$E" -eq 68 ] && printf '，撞用量上限')$([ "$E" -eq 67 ] && printf '，认证失效')）——stderr 尾部："
      tail -3 "$WORK/probe-$L.log.err" 2>/dev/null | sed 's/^/        /'
    fi
  done
fi

# ═══ 结论 ════════════════════════════════════════════════════════════════
say ""
if [ "$FILES_BROKEN" -eq 1 ]; then
  VERDICT=BROKEN; CODE=2
  say "VERDICT: BROKEN — skill 文件不完整（对应 Read gate 会硬停）；lens 状态: gpt=$GPT_LENS gemini=$GEMINI_LENS grok=$GROK_LENS"
elif [ "$GPT_LENS" = dead ] && [ "$GEMINI_LENS" = dead ]; then
  VERDICT=BROKEN; CODE=2
  say "VERDICT: BROKEN — 两只搜索 lens 均不可用；/survey 将退 3 Claude + SKIPPED banner"
elif [ "$GPT_LENS" = dead ] || [ "$GEMINI_LENS" = dead ]; then
  VERDICT=DEGRADED; CODE=1
  DEAD=$([ "$GPT_LENS" = dead ] && printf 'GPT' || printf 'Gemini')
  say "VERDICT: DEGRADED — $DEAD lens 不可用；/survey 将走 PARTIAL banner 降级$([ "$GPT_LENS" = dead ] && printf '（Phase 6 主评审按替补链改用 grok）' || printf '（tiebreaker 改用 grok）')"
else
  VERDICT=HEALTHY; CODE=0
  EXTRA=""
  [ "$FIX_COUNT" -gt 0 ] && EXTRA="（自动修复 $FIX_COUNT 项）"
  [ "$WARN_COUNT" -gt 0 ] && EXTRA="${EXTRA}（$WARN_COUNT 条 WARN，见上）"
  say "VERDICT: HEALTHY — 两只搜索 lens 可用（gpt + gemini，均经 cursor-agent）$EXTRA"
fi
# grok 只影响 Phase 6 的红队与替补链，不参与上面的 verdict 判定——但必须**说出来**
if [ "$GROK_LENS" = dead ]; then
  say "  ↳ 替补族 grok 不可用：Phase 6 红队第二评审取消、主评审替补链只剩 gemini、tiebreaker 无法在回避时换族（verdict 不受影响）"
else
  say "  ↳ 替补族 grok 可用：Phase 6 红队第二评审会跑"
fi

if [ -n "$REPAIRS" ]; then
  say ""
  say "修复建议："
  printf '%s' "$REPAIRS"
fi

exit "$CODE"
