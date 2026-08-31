#!/usr/bin/env bash
# /survey skill — cursor-agent invocation helper
#
# 被主 Claude 调用跑一次异构 lens。**没有 opt-out flag**——/survey 只有一条高质量路径，
# 异构搜索 + 终审始终执行，不可用时自动降级（旧注释曾写 --no-hetero / --no-strict，
# 那两个 flag 从来不存在，已按异构评审意见删除）。模型**每次运行时自动解析成当前
# 账号可用的最新最强 GPT**（见下方 §模型选择 / pick_strongest），不钉死版本号。失败时
# 优雅退出，让主 Claude 加 banner 并降级到全 Claude 路径。
#
# 用法：
#   bash run-cursor-agent.sh <prompt-file> <output-file> [family]
#   bash run-cursor-agent.sh --resolve-only [family]     # 只解析模型不调用（供 doctor.sh 自检）
#
# 参数：
#   <prompt-file>  : 已含完整 prompt 的文件路径（含 Agent X 模板 + 研究问题 + 4
#                    类盲区清单 + 中文排除段；主 Claude 负责拼装）
#   <output-file>  : cursor-agent 输出落盘路径
#   [family]       : 模型家族 gpt（默认）| gemini | grok。每族各自解析"当前最强"，
#                    用于 Phase 2 双异构 lens（X1=gpt / X2=gemini）与 Phase 6
#                    事实性分歧 tiebreaker（gemini）。非法值 → exit 64
#   --resolve-only : 走完与正式调用完全相同的模型解析（含 SURVEY_CURSOR_MODEL 校验、
#                    列表 fetch deadline、fallback 回落 + WARN），把裸模型 id 打到
#                    stdout 后 exit 0，不消耗 cursor-agent 配额。检查机制靠它复用
#                    生产逻辑，杜绝 doctor 与实现两处解析漂移
#
# Exit codes：
#   0   成功，<output-file> 已写入有效内容
#   69  cursor-agent CLI 未安装（command -v 失败）—— 主 Claude 写 banner
#       "cursor-agent not found"
#   124 timeout 触发（>570s）—— 由脚本自带的 run_with_deadline watchdog 保证，**不依赖
#       系统有没有 timeout/gtimeout**。调用方 Bash 工具的 600s 是第二层保护（必须 > 570）。
#   67  认证失效（凭据过期/未登录）—— 主 Claude 写 banner "cursor-agent auth failure"。
#       **不回落、不静默降级**：静默回落会把 auth 故障洗成"解析成功"，doctor 据此报
#       HEALTHY，真调用再挂（全局约束 ⑤ fail-closed）
#   68  撞 Cursor 月度额度上限（Other Models 池见底）—— 主 Claude 写 banner
#       "cursor-agent quota exhausted"，Reason 写 `quota exhausted`。**与 67 必须分开**：
#       两者的修复动作完全不同（67 去登录；68 换族 / 等重置 / 显式开 on-demand），
#       混成一个 65 会把用户指向错误的方向。撞墙会写状态文件供 doctor 快检读取
#   65  调用失败（network / 其他）—— 主 Claude 写 banner "cursor-agent error"
#   66  输出为空—— 主 Claude 写 banner "cursor-agent returned empty output"
#
# 注意：本脚本**不做** preflight 脱敏检查；survey 通用 skill 假设用户对调研内容外发
# OK。如调研内容涉敏，用户应手动 sanitize prompt 或加 --no-hetero 关闭异构。

set -uo pipefail

RESOLVE_ONLY=0
if [ "${1:-}" = "--resolve-only" ]; then
  RESOLVE_ONLY=1
  shift
  if [ $# -gt 1 ]; then
    echo "Usage: $0 --resolve-only [gpt|gemini|grok]" >&2
    exit 64
  fi
  PROMPT_FILE=""
  OUTPUT_FILE=""
  FAMILY="${1:-gpt}"
else
  if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <prompt-file> <output-file> [gpt|gemini|grok]" >&2
    echo "       $0 --resolve-only [gpt|gemini|grok]" >&2
    exit 64
  fi
  PROMPT_FILE="$1"
  OUTPUT_FILE="$2"
  FAMILY="${3:-gpt}"
fi

case "$FAMILY" in
  gpt|gemini|grok) ;;
  *) echo "ERROR: 未知模型家族 '$FAMILY'（可选 gpt | gemini | grok）" >&2; exit 64 ;;
esac

if [ "$RESOLVE_ONLY" -eq 0 ] && [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 66
fi

if ! command -v cursor-agent >/dev/null 2>&1; then
  echo "ERROR: cursor-agent not in PATH" >&2
  echo "Install: open Cursor → Settings → CLI tools (or cursor.com/cli)" >&2
  exit 69
fi

# ── 模型选择：每族各跟"最新最强（且跑得完）"，不钉死版本 ────────────────
# 从 cursor-agent --list-models 实时解析（约 1s，独立 deadline），按 $FAMILY 挑：
#
#   全族通排（先过这道）：排除 -fast（插队优先队列，额外计费，模型本身不更强）、
#     -none/-low/-medium（低档）、codex（编码专用）、mini/nano/lite/flash（小模型）、
#     preview/realtime/audio/image/embed/tts（非通用推理形态）。
#   **-max 全族排除**：2026-07-21 实测 gpt-5.6-sol-max 跑同一评审任务要 690s，
#     超过调用方 Bash 工具 600s 硬上限（工具参数封顶 600000ms）→ 必然超时、异构
#     评审整段丢失；同任务 xhigh 只要 314s。要强上 max 用 SURVEY_CURSOR_MODEL。
#
#   gpt    : ^gpt-  且**必须** -high / -xhigh / -extra-high 结尾（裸 id 如 gpt-7
#            默认只是 medium 档，不入选；未知形态如 gpt-6-preview 一律拒）
#   gemini : ^gemini-  且**必须**含 pro（flash 版本号可能更高但那是小模型，已在
#            通排里排掉；gemini 当前形态无 effort 后缀，故此族不要求后缀）
#   grok   : ^cursor-grok-  且**必须** -high / -xhigh 结尾（注意 id 带 cursor- 前缀）
#
#   比较：主版本 → 次版本 → effort 档（xhigh > high > 无后缀）→ 列表先出现者。
#   ⚠️ 最后这条只是**启发式**：Cursor 并未承诺 --list-models 的顺序代表推荐度或
#      能力排序，它只是同版同档多代号（sol/terra/luna）并存时的确定性 tie-break。
# 取列表失败 / 超时 / 未登录 / 无候选 → 回落到该族 FALLBACK（打 WARN）。
# 想手动钉某个模型：SURVEY_CURSOR_MODEL=gpt-5.6-sol-max ./run-cursor-agent.sh ...
#   （该变量**跨族生效**：钉了就不再按 family 解析）
case "$FAMILY" in                      # 各族 fallback：2026-08-15 复核仍在实时列表
  gpt)    FALLBACK_MODEL="gpt-5.6-sol-xhigh" ;;   # 314s 跑完
  gemini) FALLBACK_MODEL="gemini-3.1-pro" ;;      # 实测可联网搜索；⚠️ 该族当前**仅此一个**
                                                  # 非 flash 候选，X2 与 tiebreaker 都吊在它身上
  grok)   FALLBACK_MODEL="cursor-grok-4.6-high" ;; # 2026-08-15 实测：联网搜索可用，
                                                   # 但玩具 prompt 也要 263s（该族基础延迟高）
esac
LIST_DEADLINE=20                     # 取模型列表的独立超时（秒）

# ── 额度状态文件：真调用撞额度墙时留痕，供 doctor 快检读取 ─────────────────
# 为什么需要它：2026-08-30 实测，Other Models 池（gpt/gemini/claude 等三方模型）见底时
# `cursor-agent --list-models` **仍 exit 0 并返回完整的 206 行列表**，模型解析全部成功，
# 额度故障对"不耗配额的快检"完全隐形——只有真调用才会报 ActionRequiredError。
# 所以额度只能由真调用发现；发现了就写状态文件，让下一次 doctor 快检读得到，
# 而不是等到 Phase 2 双眼齐灭才知道（这正是本 skill 在认证上栽过的同一个坑）。
SURVEY_STATE_DIR="${SURVEY_STATE_DIR:-$HOME/.cache/survey}"
QUOTA_STATE="$SURVEY_STATE_DIR/quota-state"

# 额度错误的判据。锚定 2026-08-30 实测原文（cursor-agent 2026.08.25-3e8eec8）：
#   ActionRequiredError: You've hit your usage limit You've saved $NNN on API model
#   usage this month with <plan>. Switch to a different model or set a Spend Limit to
#   continue with this model. Your usage limits will reset when your monthly cycle
#   ends on 1/31/2099.
# 故意不匹配裸 "rate limit"——那是短时限流，重试即可，与月度额度耗尽是两回事
is_quota_error() { grep -qiE "hit your usage limit|ActionRequiredError|Spend Limit|usage limits will reset" "$1" 2>/dev/null; }

clear_quota_block() { # $1=family —— 成功调用是"该族此刻可用"的直接证据，正面证据推翻负面留痕
  [ -s "$QUOTA_STATE" ] || return 0
  local tmp="$QUOTA_STATE.ok.$$"
  grep -v "^$1	" "$QUOTA_STATE" 2>/dev/null > "$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$QUOTA_STATE" 2>/dev/null || rm -f "$tmp"
  else rm -f "$tmp" "$QUOTA_STATE" 2>/dev/null; fi
}

record_quota_block() { # $1=family $2=错误原文
  mkdir -p "$SURVEY_STATE_DIR" 2>/dev/null || return 0
  local reset now tmp
  # 从 "...cycle ends on 1/31/2099." 里抠重置日；抠不到写 "-"（只用于展示，不参与判定）
  reset=$(printf '%s' "$2" | sed -n 's/.*cycle ends on \([0-9][0-9/]*\).*/\1/p' | head -1)
  now=$(date +%s)
  tmp="$QUOTA_STATE.$$"
  grep -v "^$1	" "$QUOTA_STATE" 2>/dev/null > "$tmp"
  printf '%s\t%s\t%s\n' "$1" "$now" "${reset:--}" >> "$tmp"
  mv -f "$tmp" "$QUOTA_STATE" 2>/dev/null || rm -f "$tmp"
}

# 递归杀 $2 的全部后代再杀自身（深度优先）——cursor-agent 可能派生 node 子进程，
# 只杀一层会留孤儿继续烧配额（异构评审(GPT)指出）
kill_tree() { # $1=信号 $2=pid
  local sig="$1" pid="$2" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$sig" "$c"; done
  kill "-$sig" "$pid" 2>/dev/null
}

# 取模型列表：写进 $1；返回非 0 = 失败或超时（**不接受**"非零退出但有部分输出"）
# deadline 用真实时间不用循环计数：系统睡眠/调度延迟下 ticks 会失真（异构评审指出）
# 返回 0=成功 / 2=认证失效 / 1=超时或其它失败。stderr 落 <$1>.err **不再丢弃**：
# 2026-08-30 实测，凭据过期时这行 stderr 是 "Error: Authentication required"——唯一能
# 定位根因的证据。旧版 `2>/dev/null` 把它扔了，且超时与认证失败同样 return 1，于是
# 调用方只能报 "取模型列表失败或超时（>20s）"；而实测该 WARN 在 1s 内就打出来，
# 文案本身是假的，直接把人误导到网络/模型命名方向
fetch_model_list() {
  local out="$1" err="$1.err" pid t0 rc
  cursor-agent --list-models >"$out" 2>"$err" &
  pid=$!; t0=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(( $(date +%s) - t0 ))" -ge "$LIST_DEADLINE" ]; then
      kill_tree 9 "$pid"
      wait "$pid" 2>/dev/null
      return 1
    fi
    sleep 0.5
  done
  wait "$pid"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  grep -qiE "authentication required|authentication failed|stored authentication is invalid|invalid or expired|agent login|CURSOR_API_KEY" "$err" 2>/dev/null && return 2
  return 1
}

# 从列表里挑该族最强候选（全程单个 awk：不用 sort|head，避免 SIGPIPE / locale 依赖）
# 用法：pick_strongest <gpt|gemini|grok> [xhigh|high] < <模型列表>
# 第二参 = effort 档**偏好**（缺省 xhigh）：版本仍然优先，同版本内先挑偏好档、
# 该档没货自动落到另一档（可用性优先，不因档位缺货而整族失败）。
# 为什么可调：Phase 2 搜索是检索型任务，推理深度收益小、xhigh 徒增 2-3 分钟等待；
# Phase 6 全文评审才需要 xhigh（见 references/cursor-agent-invocation.md §档位配置）
pick_strongest() {
  awk -v fam="$1" -v pref="${2:-xhigh}" '
    BEGIN {
      bmaj = -1; bmin = -1; bpat = -1; btier = -1; best = ""
      if (fam == "gpt")         pfx = "gpt-"
      else if (fam == "gemini") pfx = "gemini-"
      else if (fam == "grok")   pfx = "cursor-grok-"
      else exit 1
    }
    /^[a-z0-9]/ && index($0, " - ") > 0 {
      id = $1
      # ── 全族通排 ──
      if (id ~ /-fast$/) next
      if (id ~ /-none$/ || id ~ /-low$/ || id ~ /-medium$/ || id ~ /-max$/) next
      # ⚠️ 这些必须带前导 `-` 按**分段**匹配，不能用裸子串：
      #    裸 /mini/ 会把 ge-MINI-* 整族误杀（实测踩过）
      if (id ~ /-codex/ || id ~ /-mini/ || id ~ /-nano/ || id ~ /-lite/ || id ~ /-flash/) next
      if (id ~ /-preview/ || id ~ /-realtime/ || id ~ /-audio/ || id ~ /-image/ ||
          id ~ /-embed/ || id ~ /-tts/) next
      if (substr(id, 1, length(pfx)) != pfx) next
      # ── 每族白名单（未知形态一律拒）──
      if (fam == "gpt" || fam == "grok") {
        if (id !~ /-high$/ && id !~ /-xhigh$/ && id !~ /-extra-high$/) next
      } else if (fam == "gemini") {
        if (id !~ /pro/) next
      }
      # tier = 与偏好档的匹配度（2=偏好档 1=另一档 0=无后缀）；注意 /-high$/ 会
      # 误匹配 -extra-high 结尾，判 high 档必须先排掉 extra-high
      is_x = (id ~ /-xhigh$/ || id ~ /-extra-high$/)
      is_h = (id ~ /-high$/ && id !~ /-extra-high$/)
      if (pref == "high") {
        if (is_h) tier = 2; else if (is_x) tier = 1; else tier = 0
      } else {
        if (is_x) tier = 2; else if (is_h) tier = 1; else tier = 0
      }
      rest = substr(id, length(pfx) + 1)
      p = index(rest, "-")
      if (p == 0) next
      ver = substr(rest, 1, p - 1)
      if (ver !~ /^[0-9]+(\.[0-9]+)*$/) next
      # 版本按段比较，不能把点后整体当小数：\"0.10\"+0=0.1 会让 6.0.10 输给 6.0.2
      # （异构评审(GPT)给出的可复现反例）
      n = split(ver, seg, ".")
      vmaj = seg[1] + 0
      vmin = (n >= 2) ? seg[2] + 0 : 0
      vpat = (n >= 3) ? seg[3] + 0 : 0
      if (vmaj > bmaj ||
          (vmaj == bmaj && (vmin > bmin ||
          (vmin == bmin && (vpat > bpat ||
          (vpat == bpat && tier > btier)))))) {
        bmaj = vmaj; bmin = vmin; bpat = vpat; btier = tier; best = id
      }
    }
    END { if (best != "") print best }
  '
}

# effort 档偏好（仅影响 gpt/grok 族的自动解析；gemini 现无档、钉值不受影响）
EFFORT="${SURVEY_CURSOR_EFFORT:-xhigh}"
case "$EFFORT" in
  xhigh|high) ;;
  *) echo "WARN: SURVEY_CURSOR_EFFORT='${EFFORT}' 非法（可选 high | xhigh），回落 xhigh" >&2
     EFFORT=xhigh ;;
esac

MODEL=""
if [ -n "${SURVEY_CURSOR_MODEL:-}" ]; then
  # ① 字符集校验（防控制字符污染日志）；不存在注入风险——$MODEL 是独立 argv
  case "$SURVEY_CURSOR_MODEL" in
    *[!A-Za-z0-9._-]*)
      echo "WARN: SURVEY_CURSOR_MODEL 含非法字符，忽略，改用自动解析" >&2 ;;
    *) MODEL="$SURVEY_CURSOR_MODEL" ;;
  esac
  # ② **必须与 $FAMILY 同族**——这是结构性保证，不是提醒。
  #    Phase 6 要求"终审(gpt) 与 tiebreaker(gemini) 异族"，若主 Claude 把钉给 gpt 的值
  #    带到 gemini 调用上（export 后忘了 unset），tiebreaker 就会偷偷跑成 GPT 自审自签，
  #    "异族裁决"整个设计当场失效且**没有任何外部迹象**。所以在这里硬拦。
  if [ -n "$MODEL" ]; then
    case "$FAMILY" in
      gpt)    EXPECT_PFX="gpt-" ;;
      gemini) EXPECT_PFX="gemini-" ;;
      grok)   EXPECT_PFX="cursor-grok-" ;;
    esac
    case "$MODEL" in
      "$EXPECT_PFX"*) ;;
      *) echo "WARN: SURVEY_CURSOR_MODEL='${MODEL}' 不属于 family=${FAMILY}（需以 '${EXPECT_PFX}' 开头），已忽略，改用自动解析" >&2
         MODEL="" ;;
    esac
  fi
fi

LIST_FILE=""
if [ -z "$MODEL" ]; then
  LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/survey-models.XXXXXX")
  fetch_model_list "$LIST_FILE"; LIST_RC=$?
  case "$LIST_RC" in
    0) MODEL=$(pick_strongest "$FAMILY" "$EFFORT" < "$LIST_FILE") ;;
    2) # 认证失效**不做**静默回落：回落只会让 --resolve-only exit 0，把 auth 故障洗成
       # "解析成功"，doctor 据此报 HEALTHY，真调用再必挂（全局约束 ⑤ fail-closed）
       echo "ERROR: [$FAMILY] cursor-agent 认证失效——跑 cursor-agent login" >&2
       head -1 "$LIST_FILE.err" >&2 2>/dev/null
       rm -f "$LIST_FILE" "$LIST_FILE.err"
       exit 67 ;;
    *) echo "WARN: 取模型列表失败或超时（>${LIST_DEADLINE}s，非认证原因）" >&2 ;;
  esac
  rm -f "$LIST_FILE" "$LIST_FILE.err"
fi

if [ -z "$MODEL" ]; then
  MODEL="$FALLBACK_MODEL"
  echo "WARN: [$FAMILY] 未解析到可用模型，回落到 $MODEL" >&2
fi
printf 'MODEL: %s (family=%s)\n' "$MODEL" "$FAMILY" >&2

if [ "$RESOLVE_ONLY" -eq 1 ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# 内层超时，默认 570s——同步调用时**必须小于**调用方 Bash 工具的 600000ms 硬上限
# （上限不可调，BASH_MAX_TIMEOUT_MS 有已知 bug 不生效，见 claude-code issue #34138），
# 否则外层先到期、脚本来不及返回自己的 124。
# 重活（Phase 6 全文评审等 >570s 任务）不要抬这里硬扛同步窗口，改走
# run-cursor-agent-async.sh（nohup 脱离进程树，deadline 由它传入，可 30 分钟）。
# 校验：仅接受 30-7200 的纯数字，非法值回落 570 并打 WARN。
TIMEOUT_SEC="${SURVEY_TIMEOUT_SEC:-570}"
case "$TIMEOUT_SEC" in
  *[!0-9]*|"") echo "WARN: SURVEY_TIMEOUT_SEC='${SURVEY_TIMEOUT_SEC:-}' 非法，回落 570" >&2; TIMEOUT_SEC=570 ;;
  *) if [ "$TIMEOUT_SEC" -lt 5 ] || [ "$TIMEOUT_SEC" -gt 7200 ]; then
       echo "WARN: SURVEY_TIMEOUT_SEC=${TIMEOUT_SEC} 超出 5-7200，回落 570" >&2; TIMEOUT_SEC=570
     fi ;;
esac

# 每次调用独立的 stderr 日志——固定路径会在两个 survey 并发时互相覆盖（用户常开多窗）
ERR_LOG=$(mktemp "${TMPDIR:-/tmp}/survey-cursor-agent-stderr.XXXXXX")
trap 'rm -f "$ERR_LOG"' EXIT

# 自带可移植 watchdog，**不依赖 timeout/gtimeout**——macOS 默认没装 GNU coreutils，
# 原来那条路径等于"脚本内根本没有超时保护，全靠调用方 Bash 工具的 timeout"。异构评审
# 指出：调用方一旦忘了传 timeout 就会永久挂住。现在无论环境如何都有内层保护。
# 返回 124 表示超时（先 TERM 再 KILL），其余透传子进程退出码。
run_with_deadline() { # $1=秒；其余=要跑的命令
  local deadline="$1" t0; shift
  "$@" > "$OUTPUT_FILE" 2>"$ERR_LOG" &
  local pid=$!; t0=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(( $(date +%s) - t0 ))" -ge "$deadline" ]; then
      kill_tree TERM "$pid"
      sleep 2
      kill_tree 9 "$pid"
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.5
  done
  wait "$pid"
}

# 调用 cursor-agent
# 注意：用 "$(cat "$PROMPT_FILE")" 把 prompt 作为单一 argv 传入；超大 prompt 可能
# 触发 ARG_MAX，必要时未来改成 stdin
run_with_deadline "$TIMEOUT_SEC" cursor-agent \
  --print \
  --model "$MODEL" \
  --output-format text \
  --sandbox enabled \
  --force \
  "$(cat "$PROMPT_FILE")"

EXIT=$?

if [ "$EXIT" -eq 124 ] || [ "$EXIT" -eq 137 ]; then
  echo "ERROR: cursor-agent timeout (>${TIMEOUT_SEC}s)" >&2
  exit 124
fi

if [ "$EXIT" -ne 0 ]; then
  # 分类顺序要紧：额度 → 认证 → 其它。额度文案里不含 auth 关键词，反之亦然，
  # 但把额度排在前面可保证将来文案变动时不会被 auth 的宽正则抢走（那会把用户
  # 指向"去登录"，而登录对额度耗尽毫无用处）
  if is_quota_error "$ERR_LOG"; then
    record_quota_block "$FAMILY" "$(tail -5 "$ERR_LOG" 2>/dev/null)"
    echo "ERROR: [$FAMILY] 撞到 Cursor 月度额度上限——不是认证问题、也不是超时" >&2
    grep -iE "hit your usage limit|usage limits will reset" "$ERR_LOG" 2>/dev/null | head -2 | sed 's/^/       /' >&2
    echo "       该族本月不可用。三选一：换族（grok 走 Cursor Models 池，通常仍有余额）／等额度重置／到 Cursor 后台显式开启 on-demand（另计费，用完记得关）" >&2
    exit 68
  fi
  if grep -qiE "authentication required|authentication failed|stored authentication is invalid|invalid or expired" "$ERR_LOG" 2>/dev/null; then
    echo "ERROR: [$FAMILY] cursor-agent 认证失效——跑 cursor-agent login" >&2
    tail -3 "$ERR_LOG" >&2 || true
    exit 67
  fi
  echo "ERROR: cursor-agent exited $EXIT" >&2
  echo "stderr tail:" >&2
  tail -20 "$ERR_LOG" >&2 || true
  exit 65
fi

if [ ! -s "$OUTPUT_FILE" ]; then
  echo "ERROR: cursor-agent returned empty output" >&2
  exit 66
fi

# 成功即清该族留痕：额度按月重置，重置后第一次成功调用就该让 doctor 立刻恢复绿灯，
# 而不是干等 24h TTL 过期（doctor L3.5 的提示文案也是这么向用户承诺的）
clear_quota_block "$FAMILY"

echo "OK: cursor-agent ($MODEL) wrote $(wc -c < "$OUTPUT_FILE") bytes to $OUTPUT_FILE"
exit 0
