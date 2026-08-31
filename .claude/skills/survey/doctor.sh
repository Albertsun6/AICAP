#!/usr/bin/env bash
# /survey — 异构链路自检 + 自修复（doctor）
#
# 为什么要有这个文件：异构眼（cursor-agent 各族 lens）的故障此前只能在
# 正式调研跑到一半时以"降级 banner"形式暴露——环境坏了（未安装/未登录/模型下架/
# 文件缺失/权限丢失）用户要到 Phase 2 才知道。doctor 把这些检查前置成秒级探针，
# 能自动修的当场修（目前：脚本执行位），不能自动修的给出确切修复命令。
#
# 三族的地位不同（2026-08-15 起）：
#   gpt / gemini = Phase 2 的两只**搜索眼**，决定 verdict 档位
#   grok         = Phase 6 的红队第二评审 + 主评审/tiebreaker 的**替补族**，
#                  它死了 survey 照跑，所以只 WARN、不改 verdict，但会在结论处明说
#
# 用法：
#   bash doctor.sh            # 快检（秒级，不消耗 cursor-agent 配额）：L1 文件 + L2 CLI/登录 + L3 三族模型解析
#   bash doctor.sh --probe    # 加 L4 端到端微探针（三族各实跑一次 tiny prompt，并发；
#                             # gpt/gemini 限 180s、grok 限 300s；消耗少量 Cursor 配额）
#
# Exit codes（供主 Claude / CI 判断）：
#   0  HEALTHY  — 两只搜索 lens 可用（含"发现问题但已自动修复"与纯 WARN；grok 死也算 HEALTHY）
#   1  DEGRADED — 一只搜索 lens 不可用，survey 会走 PARTIAL banner 降级
#   2  BROKEN   — 两只搜索 lens 均不可用（未安装/未登录/关键文件缺失），survey 会退 3 Claude + SKIPPED banner
#
# 调用点：phases/02-research.md 要求主 Claude 在启动 X1/X2 前先跑一次快检（见该文件
# §cursor-agent 调度）。**doctor 结果绝不阻塞主流程**——BROKEN 也只是提前把降级
# 告知用户，降级矩阵照常生效。

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SKILL_DIR/run-cursor-agent.sh"
# 未知参数必须硬拒：--proeb 这类拼错若静默当快检跑，调用者会以为真探针已执行（异构评审(GPT)指出）
PROBE=0
case "${1:-}" in
  "") ;;
  --probe)
    [ $# -gt 1 ] && { echo "ERROR: --probe 不接受多余参数" >&2; exit 64; }
    PROBE=1 ;;
  *) echo "ERROR: 未知参数 '${1}'（仅支持 --probe）" >&2; exit 64 ;;
esac

# ── 结果记账 ─────────────────────────────────────────────────────────────
# lens 状态：ok | dead；核心故障（双搜索 lens 齐灭）单独记
# gpt/gemini = Phase 2 的两只搜索眼，决定 verdict 档位
# grok       = Phase 6 的红队 + 主评审/tiebreaker 替补族，**不参与 verdict 判定**：
#              它死了 survey 照跑（红队取消、替补链变短），所以只 WARN 不 FAIL
GPT_LENS=ok
GEMINI_LENS=ok
GROK_LENS=ok
CORE_BROKEN=0
WARN_COUNT=0
FIX_COUNT=0
REPAIRS=""          # 攒到最后统一打印的人工修复建议（每行一条）

say()    { printf '%s\n' "$1"; }
pass()   { say "[PASS]  $1"; }
fixed()  { say "[FIXED] $1"; FIX_COUNT=$((FIX_COUNT + 1)); }
warn()   { say "[WARN]  $1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail()   { say "[FAIL]  $1"; }
repair() { REPAIRS="${REPAIRS}  - $1
"; }

# bash 3.2 没有 nameref，用 case 分发给对应的 *_LENS 变量
set_lens() { # $1=family $2=ok|dead
  case "$1" in
    gpt)    GPT_LENS="$2" ;;
    gemini) GEMINI_LENS="$2" ;;
    grok)   GROK_LENS="$2" ;;
  esac
}
# 某族出问题时统一走这里：搜索眼（gpt/gemini）算 FAIL，替补族（grok）只算 WARN——
# 用 [FAIL] 报 grok 会让用户以为这次 survey 要降级，实际上它只是少了红队那一路
lens_bad() { # $1=family $2=消息
  if [ "$1" = grok ]; then warn "$2 —— grok 是替补族，本次 verdict 不受影响（红队取消 + 替补链变短）"
  else fail "$2"; fi
  set_lens "$1" dead
}

# 递归杀 $2 的全部后代再杀自身（深度优先）。bash 3.2 无 setsid / pkill -g，
# 只 pkill -P 会漏孙进程（cursor-agent 可能派生 node 子进程）——异构评审(GPT)指出
kill_tree() { # $1=信号 $2=pid
  local sig="$1" pid="$2" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$sig" "$c"; done
  kill "-$sig" "$pid" 2>/dev/null
}

# 带 deadline 跑命令（同 run-cursor-agent.sh 的可移植 watchdog 思路，不依赖系统 timeout）。
# $1=秒 $2=stdout落盘文件（stderr 分流到 <文件>.err——不合流：晚到的 stderr 日志会
# 污染"stdout 末行=模型 id"这类约定，异构评审(Gemini)指出）；超时递归杀整棵进程树，返回 124
run_deadline() {
  local deadline="$1" out="$2" t0; shift 2
  "$@" >"$out" 2>"${out}.err" &
  local pid=$!; t0=$(date +%s)
  # deadline 按真实时间判断，不按 sleep 次数计数：系统睡眠/调度延迟下计数会失真（异构评审指出）
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(( $(date +%s) - t0 ))" -ge "$deadline" ]; then
      kill_tree TERM "$pid"
      sleep 1
      kill_tree 9 "$pid"
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.5
  done
  wait "$pid"
}

# 只影响措辞、绝不参与 verdict：区分"从没登录/凭据已被清除"与"存过凭据但已失效"。
# status 的 exit code 在已登录/已过期/未登录三态下实测恒为 0，故只取文本、忽略退出码。
# 判定顺序不能反："Not logged in" 里含子串 "logged in"
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
# mktemp 失败（TMPDIR 不可写/磁盘满）时 WORK 为空串，后续所有路径会落到根目录——fail-fast
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "ERROR: mktemp 失败（TMPDIR='${TMPDIR:-/tmp}' 可写吗？）" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
# doctor 被 kill/Ctrl+C 时联动杀掉后台探针进程树——否则 --probe 的两个真实模型请求
# 会作为孤儿继续白烧最多 180s 配额（异构评审(Gemini)指出）
PROBE_PIDS=""
on_signal() {
  local p
  for p in $PROBE_PIDS; do kill_tree TERM "$p"; done
  exit 130
}
trap on_signal INT TERM

# ═══ L1 文件完整性 + 执行位（本地，可自动修复）═══════════════════════════
say "── L1 文件完整性 ──"

# Read gate 依赖的全部文件：任何一个缺失，对应 phase 会硬停（SKILL.md §模板缺失处理）
REQUIRED_FILES="SKILL.md
run-cursor-agent.sh
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
  # -f 且 -r 且 -s：macOS 上目录也能过 [ -s ]，无读权限的文件 Read gate 一样硬停（异构评审指出）
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
  # 数量从清单本身算，不写死——写死的话每加一个模板都要记得改这行（改漏了就骗人）
  pass "$(printf '%s\n' "$REQUIRED_FILES" | wc -l | tr -d ' ') 个 Read-gate 依赖文件齐全"
else
  # 文件残缺 ≠ 双 lens 不可用——单独记账，L2-L4 照常体检 lens，verdict 分开表述（异构评审指出）
  FILES_BROKEN=1
  repair "恢复 survey skill 文件（真实目录: $(cd "$SKILL_DIR" 2>/dev/null && pwd -P || echo "$SKILL_DIR")，到其所在 git 仓库 checkout 该目录）"
fi

# 执行位：文档统一用 `bash xxx.sh` 调用所以缺 +x 不致命，但 `./` 直调会 126
# （126 不在 exit code 降级映射表里，会被误判成未知崩溃）——这里直接修掉。
# 用数组不用字符串攒路径：SKILL_DIR 含空格时字符串会被分词切碎——异构评审(Gemini)指出
NEED_X=()
for s in "$SKILL_DIR"/*.sh; do
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
# 在 L2 之前声明：cursor-agent 未安装时 L2 不会赋值，而 set -u 下 L3 仍可能读到它们
LIVE_LIST="$WORK/live-models.txt"
LIVE_OK=0

# ═══ L2 cursor-agent CLI：安装 + 登录 ════════════════════════════════════
say "── L2 cursor-agent CLI ──"

if ! command -v cursor-agent >/dev/null 2>&1; then
  fail "cursor-agent 未安装——双异构 lens 均不可用"
  repair "安装 cursor-agent: curl https://cursor.com/install -fsS | bash（或 Cursor → Settings → CLI tools）"
  CORE_BROKEN=1
else
  VER=$(run_deadline 10 "$WORK/ver.txt" cursor-agent --version >/dev/null 2>&1; cat "$WORK/ver.txt" "$WORK/ver.txt.err" 2>/dev/null | head -1)
  pass "cursor-agent 已安装（${VER:-版本未知}，$(command -v cursor-agent)）"

  # ── 登录态判据：只认"服务端此刻认不认"，不认 status 的自述 ─────────────
  # 2026-08-30 实测：钥匙串里的 session JWT 过期 4 天（exp=1787715322 = 08-26
  # 11:35 HKT）时，`cursor-agent status` 仍 exit 0 并打印：
  #     ✓ Login successful!
  #     Logged in (unable to fetch user details)
  # 旧判据 `grep -qi "logged in"` 命中第 2 行 → doctor 报 HEALTHY/exit 0，而同一刻
  # 每一次真调用都必挂（--list-models 与真 prompt 均 "Authentication required"）。
  # status 只证明"本机存过凭据"，不证明"凭据现在有效"；且它的 exit code 三态实测
  # 恒为 0，旧代码那条 `[ "$ST_EXIT" -ne 0 ]` 分支本就是死码。
  # 换判据：--list-models 是唯一"真打服务端又不做任何模型推理"的命令（不烧配额），
  # 成功时列表直接交给 L3 复核存在性，顺带省掉 L3 原来那次重复拉取。
  run_deadline 25 "$LIVE_LIST" cursor-agent --list-models
  LM_EXIT=$?
  LM_ERR="${LIVE_LIST}.err"

  if [ "$LM_EXIT" -eq 0 ] && [ -s "$LIVE_LIST" ]; then
    LIVE_OK=1
    pass "已登录，且凭据被服务端接受（--list-models 返回 $(grep -cve '^[[:space:]]*$' "$LIVE_LIST") 行）"
  elif grep -qiE "authentication required|authentication failed|stored authentication is invalid|invalid or expired|unauthoriz|forbidden" "$LM_ERR" 2>/dev/null; then
    fail "凭据不可用——双异构 lens 均不可用（$(auth_hint)）"
    # 本机有 GUI 就走浏览器登录。**不推荐**为省这一步去造长期 CURSOR_API_KEY：
    # 它不换计费池（官方："User API keys bill to that user's plan"）、解决不了额度问题，
    # 却把一枚长期有效的凭据从 Keychain 挪到明文环境变量。只有无 GUI / CI 才值得，
    # 且那时也应从 Keychain 或 1Password 注入，不写进 dotfile（异构评审(grok)指出）
    repair "重新登录 Cursor: cursor-agent login（会话硬 60 天上限、不可续期，到期需重登）"
    CORE_BROKEN=1
  elif [ "$LM_EXIT" -eq 124 ] || grep -qiE "failed to load models|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|socket hang up|fetch failed|network|proxy|tls|certificate" "$LM_ERR" 2>/dev/null; then
    # 连不上 != 未登录：把网络抖动误报成未登录，会让用户白跑一次浏览器 login
    warn "连不上 Cursor 服务（$([ "$LM_EXIT" -eq 124 ] && printf '>25s 超时' || printf 'exit %s' "$LM_EXIT")）——登录态无法验证，正式调用可能失败"
    repair "检查网络/代理后重试: cursor-agent --list-models"
  else
    # 没见过的失败形态：fail-closed。静默放行正是本 skill 一直在防的东西
    fail "cursor-agent --list-models 以未识别的方式失败（exit ${LM_EXIT}）——按不可用处理"
    say "        stderr 首行：$(head -1 "$LM_ERR" 2>/dev/null)"
    repair "手动确认: cursor-agent --list-models；必要时 cursor-agent login"
    CORE_BROKEN=1
  fi
fi

# ═══ L3 各族模型解析（复用生产逻辑 --resolve-only，不消耗配额）═══════════
say "── L3 模型解析（gpt / gemini 两只搜索眼 + grok 替补族）──"

if [ "$CORE_BROKEN" -eq 0 ]; then
  # 实时列表供解析结果做"存在性复核"。复核不能省：SURVEY_CURSOR_MODEL 钉值与
  # FALLBACK_MODEL 都可能指向已下架的 id，解析照样 exit 0，doctor 不查列表就是
  # false-PASS（正式调用必 65）——异构评审(GPT)指出。
  # 列表已在 L2 的登录态判据里带 deadline 取过（同一个 $LIVE_LIST / $LIVE_OK），
  # 此处不重复请求；取不到的原因也已在 L2 分流成 auth / 网络 / 未识别三档
  [ "$LIVE_OK" -eq 1 ] || warn "实时模型列表取不到——解析结果无法复核存在性"

  for FAM in gpt gemini grok; do
    if run_deadline 40 "$WORK/resolve-$FAM.txt" bash "$RUNNER" --resolve-only "$FAM"; then
      # stderr 已分流到 .err，stdout 就是裸模型 id
      MODEL_ID=$(tail -1 "$WORK/resolve-$FAM.txt")
      # 空串/非法字符 = 解析隐式崩溃，fail-closed，绝不当合法 id 放行——异构评审(Gemini)指出
      case "$MODEL_ID" in
        "" | *[!A-Za-z0-9._-]*)
          lens_bad "$FAM" "[$FAM] 解析返回了空或非法 id——按 lens 不可用处理"
          continue ;;
      esac
      SRC=live
      # 只认 fallback 特有文案——runner 的"钉值跨族被拒/非法字符"WARN 不代表回落
      grep -qE "WARN: .*(回落到|取模型列表失败)" "$WORK/resolve-$FAM.txt.err" 2>/dev/null && SRC=fallback
      [ -n "${SURVEY_CURSOR_MODEL:-}" ] && [ "$MODEL_ID" = "$SURVEY_CURSOR_MODEL" ] && SRC=pinned
      # 首列精确等值匹配，不用 grep 正则：id 里的 . 会被当通配符（异构评审(GPT)指出）
      if [ "$LIVE_OK" -eq 1 ] && ! awk -v id="$MODEL_ID" '$1 == id {f=1} END {exit !f}' "$LIVE_LIST"; then
        lens_bad "$FAM" "[$FAM] ${SRC} 模型 ${MODEL_ID} 不在实时列表——正式调用必失败"
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
  say "（跳过——L2 已判双 lens 不可用）"
  GPT_LENS=dead; GEMINI_LENS=dead; GROK_LENS=dead
fi

# ═══ L3.5 月度额度（读真调用留下的痕迹；不真打、不耗配额）═════════════════
# 为什么必须单独一层：2026-08-30 实测，Other Models 池见底时 `--list-models` **仍
# exit 0 返回完整 206 行列表**，L2 登录判据全绿、L3 三族全部解析成功——额度故障对
# L1-L3 完全隐形，要到 Phase 2 真调用才炸。这与本 skill 在认证上栽过的是同一个坑
# （见 L2 注释）：拿一个便宜的自述当权威，而它根本不反映真实可用性。
# 额度只有真调用能发现，所以 run-cursor-agent.sh 撞墙时写状态文件，这里读它。
# 只认 24h 内的记录：额度按 billing cycle 按月重置，陈旧记录会误报 BROKEN；
# 读到过期记录顺手删掉，自清理。
say "── L3.5 月度额度（依据最近一次真调用的留痕）──"
QUOTA_STATE="${SURVEY_STATE_DIR:-$HOME/.cache/survey}/quota-state"
QUOTA_TTL=86400

if [ ! -s "$QUOTA_STATE" ]; then
  pass "无额度告警留痕（说明最近一次真调用没撞上月度上限）"
else
  NOW=$(date +%s)
  QS_TMP="$QUOTA_STATE.doctor.$$"
  : > "$QS_TMP"
  QUOTA_HIT=0
  while IFS="$(printf '\t')" read -r Q_FAM Q_TS Q_RESET; do
    [ -n "${Q_FAM:-}" ] || continue
    case "${Q_TS:-}" in ''|*[!0-9]*) continue ;; esac      # 脏行直接丢弃
    AGE=$(( NOW - Q_TS ))
    if [ "$AGE" -ge "$QUOTA_TTL" ]; then
      continue                                             # 过期不写回 = 自清理
    fi
    printf '%s\t%s\t%s\n' "$Q_FAM" "$Q_TS" "${Q_RESET:--}" >> "$QS_TMP"
    QUOTA_HIT=1
    case "$Q_FAM" in
      gpt|gemini|grok)
        lens_bad "$Q_FAM" "[$Q_FAM] $(( AGE / 60 )) 分钟前真调用撞到月度额度上限——该族本月不可用（重置日 ${Q_RESET:--}）" ;;
      *) warn "额度状态文件里有未知族 '$Q_FAM'，已忽略" ;;
    esac
  done < "$QUOTA_STATE"
  mv -f "$QS_TMP" "$QUOTA_STATE" 2>/dev/null || rm -f "$QS_TMP"
  if [ "$QUOTA_HIT" -eq 1 ]; then
    repair "额度耗尽三选一：改用未见底的族（grok 走 Cursor Models 池）／等重置日／到 Cursor 后台显式开 on-demand（另计费，跑完记得关）"
    say "        注：额度按月重置。重置后第一次成功调用会自动清掉留痕；也可手删 $QUOTA_STATE"
  else
    pass "额度留痕均已超过 24h（视为过期，已清理）"
  fi
fi

# ═══ L4 端到端微探针（--probe 才跑；消耗少量配额）════════════════════════
if [ "$PROBE" -eq 1 ] && [ "$CORE_BROKEN" -eq 0 ]; then
  # grok 单独给 300s：该族基础延迟明显高于另两族（2026-08-15 实测 263s 跑完一个
  # 2 问的联网 prompt），沿用 180s 会把"慢"误报成"死"
  say "── L4 端到端微探针（三族并发；gpt/gemini 各限 180s、grok 限 300s）──"
  printf 'Reply with exactly this single line and nothing else: HETERO-PROBE-OK' > "$WORK/probe-prompt.txt"

  T0=$(date +%s)
  run_deadline 180 "$WORK/probe-gpt.log"    bash "$RUNNER" "$WORK/probe-prompt.txt" "$WORK/probe-gpt.out"    gpt    &
  PID_GPT=$!
  run_deadline 180 "$WORK/probe-gemini.log" bash "$RUNNER" "$WORK/probe-prompt.txt" "$WORK/probe-gemini.out" gemini &
  PID_GEMINI=$!
  run_deadline 300 "$WORK/probe-grok.log"   bash "$RUNNER" "$WORK/probe-prompt.txt" "$WORK/probe-grok.out"   grok   &
  PID_GROK=$!
  PROBE_PIDS="$PID_GPT $PID_GEMINI $PID_GROK"
  wait "$PID_GPT";    E_GPT=$?
  wait "$PID_GEMINI"; E_GEMINI=$?
  wait "$PID_GROK";   E_GROK=$?
  PROBE_PIDS=""
  EL=$(( $(date +%s) - T0 ))

  for FAM in gpt gemini grok; do
    case "$FAM" in gpt) E=$E_GPT ;; gemini) E=$E_GEMINI ;; grok) E=$E_GROK ;; esac
    PROBE_MODEL=$(grep '^MODEL:' "$WORK/probe-$FAM.log.err" 2>/dev/null | head -1 | cut -d' ' -f2)
    # 必须核对 prompt 约定的哨兵串，不能只看"非空"：模型返回任意报错文本也非空，
    # 只看非空就是 false-PASS——异构评审(GPT)指出
    if [ "$E" -eq 0 ] && grep -q "HETERO-PROBE-OK" "$WORK/probe-$FAM.out" 2>/dev/null; then
      pass "[$FAM] 端到端探针通过（${PROBE_MODEL:-模型未知}，总耗时 ${EL}s）"
      # 真实调用成功是最强证据：推翻 L3 的瞬时失败标记（如解析偶发超时）——异构评审(GPT)指出
      set_lens "$FAM" ok
    elif [ "$E" -eq 0 ]; then
      lens_bad "$FAM" "[$FAM] 探针 exit 0 但输出不含 HETERO-PROBE-OK（模型输出异常，视同失败）——输出头部："
      head -2 "$WORK/probe-$FAM.out" 2>/dev/null | sed 's/^/        /'
    else
      lens_bad "$FAM" "[$FAM] 端到端探针失败（exit $E$([ "$E" -eq 124 ] && printf '，超时')$([ "$E" -eq 68 ] && printf '，撞月度额度上限')$([ "$E" -eq 67 ] && printf '，认证失效')）——stderr 尾部："
      tail -3 "$WORK/probe-$FAM.log.err" 2>/dev/null | sed 's/^/        /'
    fi
  done
elif [ "$PROBE" -eq 1 ]; then
  say "── L4 端到端微探针 ──"
  say "（跳过——L2 已判双 lens 不可用）"
fi

# ═══ 结论 ════════════════════════════════════════════════════════════════
say ""
if [ "$FILES_BROKEN" -eq 1 ]; then
  # 文件残缺单独表述：lens 可能都活着，但缺失文件对应的 Read gate 会硬停整个 phase，
  # 不能笼统说"双 lens 不可用"（异构评审指出）
  VERDICT=BROKEN; CODE=2
  say "VERDICT: BROKEN — skill 文件不完整（对应 Read gate 会硬停）；异构 lens 状态: gpt=$GPT_LENS gemini=$GEMINI_LENS grok=$GROK_LENS"
elif [ "$CORE_BROKEN" -eq 1 ] || { [ "$GPT_LENS" = dead ] && [ "$GEMINI_LENS" = dead ]; }; then
  VERDICT=BROKEN; CODE=2
  say "VERDICT: BROKEN — 两只搜索 lens 均不可用；/survey 将退 3 Claude + SKIPPED banner"
elif [ "$GPT_LENS" = dead ] || [ "$GEMINI_LENS" = dead ]; then
  VERDICT=DEGRADED; CODE=1
  DEAD=$([ "$GPT_LENS" = dead ] && printf 'GPT' || printf 'Gemini')
  say "VERDICT: DEGRADED — $DEAD lens 不可用；/survey 将走 PARTIAL banner 降级"
else
  VERDICT=HEALTHY; CODE=0
  EXTRA=""
  [ "$FIX_COUNT" -gt 0 ] && EXTRA="（自动修复 $FIX_COUNT 项）"
  [ "$WARN_COUNT" -gt 0 ] && EXTRA="${EXTRA}（$WARN_COUNT 条 WARN，见上）"
  say "VERDICT: HEALTHY — 两只搜索 lens 可用$EXTRA"
fi
# grok 只影响 Phase 6 的红队与替补链，不参与上面的 verdict 判定——但必须**说出来**，
# 否则用户看到 HEALTHY 会以为红队也在跑（静默降级正是本 skill 反复在防的东西）
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
