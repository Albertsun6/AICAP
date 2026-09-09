#!/usr/bin/env bash
# /survey skill — cursor-agent invocation helper（gemini / grok 两族）
#
# 被主 Claude 调用跑一次异构 lens。**没有 opt-out flag**——/survey 只有一条高质量路径，
# 异构搜索 + 终审始终执行，不可用时自动降级。模型**每次运行时自动解析成当前账号可用的
# 最新最强**（见下方 §模型选择 / pick_strongest），不钉死版本号。失败时优雅退出，让主
# Claude 加 banner 并降级。
#
# ⚠️ gpt 族已从本脚本退役（2026-09-09）：OpenAI 因 SpaceX 收购 Cursor 触发控制权变更条款，
#    宣布 2026-11-12 切断 Cursor 的模型访问且不再供新模型。gpt 族改走 run-codex.sh
#    （ChatGPT 订阅，配额池与 Cursor 独立）。传 gpt 进来直接 exit 64 并指路。
#    pick_strongest 里保留 gpt 分支只为 test-model-selection.sh 的通用规则断言，不对外暴露。
#
# 用法：
#   bash run-cursor-agent.sh <prompt-file> <output-file> <gemini|grok>
#   bash run-cursor-agent.sh --resolve-only <gemini|grok>   # 只解析模型不调用（供 doctor.sh 自检）
#
# 参数：
#   <prompt-file>  : 已含完整 prompt 的文件路径（主 Claude 负责拼装）
#   <output-file>  : cursor-agent 输出落盘路径
#   <family>       : gemini | grok（**必须显式给**，没有默认族——默认 gpt 已退役）。
#                    gemini = Phase 2 X2 + 事实 tiebreaker；grok = Phase 6 红队 + 替补族
#   --resolve-only : 走完与正式调用完全相同的模型解析（含 SURVEY_CURSOR_MODEL 校验、
#                    列表 fetch deadline、fallback 回落 + WARN），把裸模型 id 打到
#                    stdout 后 exit 0，不消耗配额。doctor 靠它复用生产逻辑，杜绝两处漂移
#
# 环境变量：
#   SURVEY_CURSOR_EFFORT=high|xhigh   grok 族 effort 偏好（缺省 xhigh；gemini 现无档）
#   SURVEY_CURSOR_MODEL=<id>          钉模型（前缀必须匹配 family，否则忽略回自动解析）
#   SURVEY_TIMEOUT_SEC=<秒>           内层 watchdog，缺省 570；async 由 runner 传入
#   SURVEY_REQUIRE_SECTIONS='## A|## B'  `|` 分隔的必含段落；缺段按 exit 66
#
# Exit codes（与 run-codex.sh 同一张表）：
#   0   成功，<output-file> 已写入有效内容
#   64  参数错（含 gpt / 非法族）—— 主 Claude 修正调用，不是降级场景
#   69  cursor-agent CLI 未安装 —— banner "cursor-agent not found"
#   124 timeout（>570s）—— 由 lib 的 run_with_deadline watchdog 保证，**不依赖系统 timeout**。
#       调用方 Bash 工具的 600s 是第二层保护（必须 > 570）
#   67  认证失效（凭据过期/未登录）—— banner "cursor-agent auth failure"。**不回落、不静默降级**：
#       静默回落会把 auth 故障洗成"解析成功"，doctor 据此报 HEALTHY，真调用再挂（⑤ fail-closed）
#   68  撞 Cursor 月度额度上限 —— banner "cursor-agent quota exhausted"。**与 67 必须分开**：
#       修复动作完全不同（67 去登录；68 换族 / 等重置 / 显式开 on-demand）。撞墙写状态文件供 doctor 读
#   65  调用失败（network / 模型不在实时列表 / 其他）—— banner "cursor-agent error"
#   66  输出为空或缺约定段落 —— banner "cursor-agent returned empty output"
#
# 注意：本脚本**不做** preflight 脱敏检查；调研内容涉敏请手动 sanitize prompt。

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_COMMON_REQUIRE=1
. "$SKILL_DIR/lib/agent-common.sh"

RESOLVE_ONLY=0
if [ "${1:-}" = "--resolve-only" ]; then
  RESOLVE_ONLY=1
  shift
  if [ $# -ne 1 ]; then
    echo "Usage: $0 --resolve-only <gemini|grok>" >&2
    exit 64
  fi
  PROMPT_FILE=""
  OUTPUT_FILE=""
  FAMILY="$1"
else
  if [ $# -ne 3 ]; then
    echo "Usage: $0 <prompt-file> <output-file> <gemini|grok>" >&2
    exit 64
  fi
  PROMPT_FILE="$1"
  OUTPUT_FILE="$2"
  FAMILY="$3"
fi

case "$FAMILY" in
  gemini|grok) ;;
  gpt) echo "ERROR: gpt 族在 cursor 通道已退役（OpenAI 2026-11-12 起切断 Cursor 模型访问）——改用 run-codex.sh" >&2; exit 64 ;;
  *) echo "ERROR: 未知模型家族 '$FAMILY'（可选 gemini | grok）" >&2; exit 64 ;;
esac

if [ "$RESOLVE_ONLY" -eq 0 ] && [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 66
fi

command -v cursor-agent >/dev/null 2>&1 || {
  echo "ERROR: cursor-agent not in PATH" >&2
  echo "Install: curl https://cursor.com/install -fsS | bash（或 Cursor → Settings → CLI tools）" >&2
  exit 69
}

# ── 模型选择：不钉版本，运行时跟该族最新最强 ──────────────────────────
# 规则（每次跑 cursor-agent --list-models 解析，~1s）：
#   gemini：^gemini- 且含 pro（该族无 effort 后缀）。⚠️ 该族当前**仅 gemini-3.1-pro 一个**非 flash
#           候选（其余 12 个全是 flash），X2 与默认 tiebreaker 都吊在它身上；它下架时 pick_strongest
#           返回空 → 回落 FALLBACK（也是它自己）→ 存在性复核不过 → run 模式 fail-closed exit 65
#   grok  ：^cursor-grok- 且 -high/-xhigh 结尾（注意 id 带 cursor- 前缀）
#   全族通排：-fast（插队计费）/ -none -low -medium（低档）/ -max（690s 必超同步窗口）/
#            -codex -mini -nano -lite -flash（小或专用）/ -preview -realtime -audio -image -embed -tts
#   ⚠️ 排除项必须带前导 `-` 按分段匹配：裸 /mini/ 会把 ge-MINI 整族误杀（实测踩过）
#   比较：主版本 → 次版本 → effort 档（xhigh > high）→ 列表先出现者（启发式 tie-break）
# 取列表失败 / 超时 / 无候选 → 回落到该族 FALLBACK（打 WARN）。认证失效**不回落**，exit 67。
case "$FAMILY" in                      # 各族 fallback：2026-09-09 复核仍在实时列表
  gemini) FALLBACK_MODEL="gemini-3.1-pro" ;;      # 实测可联网搜索；⚠️ 该族当前**仅此一个**非 flash 候选
  grok)   FALLBACK_MODEL="cursor-grok-4.6-high" ;; # 2026-08-15 实测：联网搜索可用，但玩具 prompt 也要 263s
esac
LIST_DEADLINE=20                     # 取模型列表的独立超时（秒）

# 额度错误的判据。锚定 2026-08-30 实测原文（cursor-agent 2026.08.25-3e8eec8）：
#   ActionRequiredError: You've hit your usage limit You've saved $NNN on API model
#   usage this month with <plan>. Switch to a different model or set a Spend Limit to
#   continue with this model. Your usage limits will reset when your monthly cycle
#   ends on 1/31/2099.
# 故意不匹配裸 "rate limit"——那是短时限流，重试即可，与月度额度耗尽是两回事
is_quota_error() { grep -qiE "hit your usage limit|ActionRequiredError|Spend Limit|usage limits will reset" "$1" 2>/dev/null; }

# 取模型列表：写进 $1；返回 0=成功 / 2=认证失效 / 1=超时或其它失败
# （**不接受**"非零退出但有部分输出"）。stderr 落 <$1>.err 不丢弃：凭据过期时这行 stderr
# 是 "Error: Authentication required"——唯一能定位根因的证据（2026-08-30 实测）
fetch_model_list() {
  local out="$1" err="$1.err" rc
  run_with_deadline "$LIST_DEADLINE" "$out" "$err" -- cursor-agent --list-models
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  grep -qiE "authentication required|authentication failed|stored authentication is invalid|invalid or expired|agent login|CURSOR_API_KEY" "$err" 2>/dev/null && return 2
  return 1
}

# 从列表里挑该族最强候选（全程单个 awk：不用 sort|head，避免 SIGPIPE / locale 依赖）
# 用法：pick_strongest <gpt|gemini|grok> [xhigh|high] < <模型列表>
# 第二参 = effort 档**偏好**（缺省 xhigh）：版本仍然优先，同版本内先挑偏好档、
# 该档没货自动落到另一档（可用性优先，不因档位缺货而整族失败）。
# gpt 分支只服务 test-model-selection.sh 的通用规则断言（CLI 层已拒绝 gpt）。
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
      # 版本按段比较，不能把点后整体当小数："0.10"+0=0.1 会让 6.0.10 输给 6.0.2
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

# effort 档偏好（仅影响 grok 族的自动解析；gemini 现无档、钉值不受影响）
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
  # ② **必须与 $FAMILY 同族**——这是结构性保证。Phase 6 要求"主评审(codex/gpt) 与
  #    tiebreaker(gemini) 异族"，若主 Claude 把钉给 grok 的值带到 gemini 调用上（export 后
  #    忘了 unset），tiebreaker 就会偷偷跑成 grok（红队自己裁自己的争议）且**没有任何外部迹象**。
  if [ -n "$MODEL" ]; then
    case "$FAMILY" in
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

LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/survey-models.XXXXXX")
fetch_model_list "$LIST_FILE"; LIST_RC=$?
case "$LIST_RC" in
  0) [ -z "$MODEL" ] && MODEL=$(pick_strongest "$FAMILY" "$EFFORT" < "$LIST_FILE") ;;
  2) # 认证失效**不做**静默回落：回落只会让 --resolve-only exit 0，把 auth 故障洗成
     # "解析成功"，doctor 据此报 HEALTHY，真调用再必挂（全局约束 ⑤ fail-closed）
     echo "ERROR: [$FAMILY] cursor-agent 认证失效——跑 cursor-agent login" >&2
     head -1 "$LIST_FILE.err" >&2 2>/dev/null
     rm -f "$LIST_FILE" "$LIST_FILE.err"
     exit 67 ;;
  *) echo "WARN: 取模型列表失败或超时（>${LIST_DEADLINE}s，非认证原因）" >&2 ;;
esac

if [ -z "$MODEL" ]; then
  MODEL="$FALLBACK_MODEL"
  echo "WARN: [$FAMILY] 未解析到可用模型，回落到 $MODEL" >&2
fi
printf 'MODEL: %s (family=%s)\n' "$MODEL" "$FAMILY" >&2

# 存在性复核：钉值 / fallback 都可能指向已下架 id（gemini 的 fallback 就是它要保护的那个单点）。
# 列表拿到了却查无此 id → run 模式 fail-closed，别烧一次必失败的调用；resolve 模式仍打 id
# 供 doctor 自己复核（doctor 有更好的文案与修复建议）
LISTED=1
if [ "$LIST_RC" -eq 0 ] && ! awk -v id="$MODEL" '$1 == id {f=1} END {exit !f}' "$LIST_FILE"; then
  LISTED=0
  echo "WARN: [$FAMILY] 模型 ${MODEL} 不在实时列表中——正式调用必失败" >&2
fi
rm -f "$LIST_FILE" "$LIST_FILE.err"

if [ "$RESOLVE_ONLY" -eq 1 ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi
if [ "$LISTED" -eq 0 ]; then
  echo "ERROR: [$FAMILY] 模型 ${MODEL} 不在实时列表，跳过调用（钉值请改 SURVEY_CURSOR_MODEL；回落值请更新 FALLBACK_MODEL 并跑 test-model-selection.sh）" >&2
  exit 65
fi

# 内层超时，默认 570s——同步调用时**必须小于**调用方 Bash 工具的 600000ms 硬上限
# （上限不可调，BASH_MAX_TIMEOUT_MS 有已知 bug 不生效，见 claude-code issue #34138），
# 否则外层先到期、脚本来不及返回自己的 124。重活走 run-agent-async.sh（deadline 由它传入）。
TIMEOUT_SEC=$(validate_seconds "${SURVEY_TIMEOUT_SEC:-570}" 5 7200 570 SURVEY_TIMEOUT_SEC)

# 每次调用独立的工作目录：stderr 日志（固定路径会在两个 survey 并发时互相覆盖）+
# 空 workspace（不传 --workspace 时 cursor-agent 以 cwd 为工作区，会把被调研仓库的
# .cursor/rules 与 AGENTS.md 逐字注入所有族的上下文——2026-09-09 差分探针实测；
# 调研本仓库时这是"项目规则反向污染调研结论"的自污染路径）
WORK=$(mktemp -d "${TMPDIR:-/tmp}/survey-cursor-agent.XXXXXX")
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "ERROR: mktemp 失败" >&2; exit 65; }
trap 'rm -rf "$WORK"' EXIT
ERR_LOG="$WORK/stderr.log"
RUN_WS="$WORK/ws"; mkdir -p "$RUN_WS"

# 调用 cursor-agent。prompt 用 "$(cat)" 作为单一 argv 传入；超大 prompt 可能触发 ARG_MAX，
# 必要时未来改成 stdin
run_with_deadline "$TIMEOUT_SEC" "$OUTPUT_FILE" "$ERR_LOG" -- cursor-agent \
  --print \
  --model "$MODEL" \
  --output-format text \
  --sandbox enabled \
  --force \
  --workspace "$RUN_WS" \
  "$(cat "$PROMPT_FILE")"

EXIT=$?

if [ "$EXIT" -eq 124 ] || [ "$EXIT" -eq 137 ]; then
  echo "ERROR: cursor-agent timeout (>${TIMEOUT_SEC}s)" >&2
  exit 124
fi

if [ "$EXIT" -ne 0 ]; then
  # 分类顺序要紧：额度 → 认证 → 其它。额度文案里不含 auth 关键词，反之亦然，
  # 但把额度排在前面可保证将来文案变动时不会被 auth 的宽正则抢走
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

if ! check_required_sections "$OUTPUT_FILE"; then
  echo "ERROR: cursor-agent 输出缺少约定段落——按空输出处理" >&2
  exit 66
fi

# 成功即清该族留痕：额度按月重置，重置后第一次成功调用就该让 doctor 立刻恢复绿灯
clear_quota_block "$FAMILY"

echo "OK: cursor-agent ($MODEL) wrote $(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes to $OUTPUT_FILE"
exit 0
