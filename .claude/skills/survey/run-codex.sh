#!/usr/bin/env bash
# /survey — codex 通道调用 helper（与 run-cursor-agent.sh **契约对齐**）
#
# 为什么要有它（2026-09-09）：OpenAI 因 SpaceX 收购 Cursor 触发控制权变更条款，宣布 2026-11-12
# 切断 Cursor 的 GPT 模型访问且不再供新模型。gpt 族在 cursor 通道整体退役，codex CLI
# （走用户的 ChatGPT 订阅，配额池与 Cursor **完全独立**）成为 gpt 族唯一通道：
# Phase 2 X1 搜索眼 + Phase 6 主评审 R1/R2/R3 都走这里。cursor 只剩 gemini + grok。
# 副作用是好事：X1(codex) 与 X2(cursor gemini) 不再共池共凭据，"两眼各自独立降级"从假变真。
#
# 契约与 run-cursor-agent.sh 逐位对齐，主 Claude 的调用/降级逻辑不分叉：
# 同样的 <prompt-file> <output-file> [lens] 位置参数、同样的 exit code。
#
# 用法：
#   bash run-codex.sh <prompt-file> <output-file> [codex]
#   bash run-codex.sh --resolve-only [codex]   # 解析模型 id（不发模型请求、不耗配额）
#   bash run-codex.sh --auth-check             # 零配额认证实打（doctor 用；**不解析模型**）
#
# 环境变量：
#   SURVEY_CODEX_EFFORT=low|medium|high|xhigh   缺省 xhigh。X1 搜索用 high（检索型任务，实测
#                                               302-491s；xhigh 604s 会撞同步窗口），Phase 6 评审用 xhigh
#   SURVEY_CODEX_MODEL=<id>                     钉模型（跳过目录解析；仍做存在性复核）
#   SURVEY_TIMEOUT_SEC=<秒>                     内层 watchdog，缺省 570（同步窗口）；async 由 runner 传入
#   SURVEY_REQUIRE_SECTIONS='## A|## B'         `|` 分隔的必含段落；缺段按 exit 66
#
# Exit codes（与 run-cursor-agent.sh 同一张表）：
#   0 成功 / 64 参数错或 CLI 契约变了 / 65 调用失败或认证判不出(fail-closed) / 66 空输出或缺段
#   67 认证失效 / 68 配额耗尽 / 69 未安装 / 124 超时
#
# 与 cursor 版的**三处客观差异**（不是风格差异）：
#   ① 只有 OpenAI 一族：位置参数固定 `codex`（留着占位是为了主 Claude 的调用形状不分叉）
#   ② 模型解析不打服务端：codex 无 --list-models；`codex debug models` 读本地目录
#      （实测：断网 exit 0 / 未登录 exit 0 且返回**另一份内置目录**）。所以"解析成功"
#      **不构成任何可用性证据**，认证必须由 --auth-check 单独实打（fail-closed）
#   ③ 失败分类不看 exit code：codex exec 的 401 认证 / 400 模型不存在 / 配额墙**全部** exit 1
#      （实测）。分类只能读 `--json` 事件流里的 turn.failed / error 的 message

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_COMMON_REQUIRE=1
. "$SKILL_DIR/lib/agent-common.sh"

LENS=codex                       # 额度留痕 / doctor 记账用的 lens 名
FALLBACK_MODEL="gpt-6-astra"     # 2026-09-09 实测：目录 priority=1，X1 与评审都跑通
CATALOG_TTL=86400                # 模型目录新鲜度上限（秒）；超龄只 WARN 不算解析失败

MODE=run
case "${1:-}" in
  --resolve-only) MODE=resolve; shift ;;
  --auth-check)   MODE=auth;    shift ;;
esac

case "$MODE" in
  run)
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
      echo "Usage: $0 <prompt-file> <output-file> [codex]" >&2
      echo "       $0 --resolve-only [codex]" >&2
      echo "       $0 --auth-check" >&2
      exit 64
    fi
    PROMPT_FILE="$1"; OUTPUT_FILE="$2"; FAMILY="${3:-codex}" ;;
  resolve)
    [ $# -gt 1 ] && { echo "Usage: $0 --resolve-only [codex]" >&2; exit 64; }
    PROMPT_FILE=""; OUTPUT_FILE=""; FAMILY="${1:-codex}" ;;
  auth)
    [ $# -gt 0 ] && { echo "ERROR: --auth-check 不接受参数" >&2; exit 64; }
    PROMPT_FILE=""; OUTPUT_FILE=""; FAMILY=codex ;;
esac

case "$FAMILY" in
  codex) ;;
  *) echo "ERROR: run-codex.sh 只有一个 lens 'codex'（收到 '$FAMILY'）——gemini/grok 走 run-cursor-agent.sh" >&2; exit 64 ;;
esac

command -v codex >/dev/null 2>&1 || {
  echo "ERROR: codex not in PATH" >&2
  echo "Install: npm i -g @openai/codex && codex login" >&2
  exit 69
}
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 缺失（事件流分类与目录解析都依赖它）" >&2; exit 65; }

[ "$MODE" = run ] && [ ! -f "$PROMPT_FILE" ] && { echo "ERROR: prompt file not found: $PROMPT_FILE" >&2; exit 66; }

# ══ 认证实打：零配额、零模型推理 ═══════════════════════════════════════
# 打 codex 自己刷模型目录用的端点（原文来自 codex 报错行：
#   codex_models_manager: failed to refresh available models: unexpected status 401 …
#   url: https://chatgpt.com/backend-api/codex/models?client_version=<v>）
# 实测：有效 token→200(2.2s)；伪造签名→401；无 token→401。
# **绝不**用 `codex doctor` 的 auth.credentials 当认证门：实测把 auth.json 签名改坏后它照样
# overallStatus=warning / exit 0 / "auth is configured"——它只看磁盘上有没有 token，
# 与 cursor-agent `status` 自称 "Logged in" 是同一个坑。
# 唯一有信息量的是 doctor --json 里 network.websocket_reachability（真带凭据握手），
# 这里只在 curl 探针"判不出"时把它当第二意见，避免未公开端点搬家时误报 BROKEN。
# 返回：0=服务端认这把 token / 2=服务端拒绝 / 3=判不出（网络/缺依赖）→ 调用方 fail-closed
auth_probe() {
  local authf="${CODEX_HOME:-$HOME/.codex}/auth.json" tok exp now ver code
  [ -r "$authf" ] || { echo "AUTH: no auth.json at $authf" >&2; return 2; }
  command -v curl >/dev/null 2>&1 || { echo "AUTH: curl 缺失，判不出" >&2; return 3; }
  tok=$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("tokens") or {}).get("access_token") or "")' "$authf" 2>/dev/null)
  [ -n "$tok" ] || { echo "AUTH: auth.json 里没有 access_token（API-key 模式？）" >&2; return 2; }
  # 本地 exp 先看一眼：已过期 → 本探针必然 401，但 codex 真调用会先尝试 refresh，
  # 所以这种情况**不判死**，只报 needs-refresh，交给真调用去刷（避免假 BROKEN）
  exp=$(python3 -c '
import base64,json,sys
t=sys.argv[1].split(".")
b=t[1]+"="*(-len(t[1])%4)
print(json.loads(base64.urlsafe_b64decode(b)).get("exp",0))' "$tok" 2>/dev/null)
  now=$(date +%s)
  ver=$(codex --version 2>/dev/null | awk '{print $2}')
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
        -H "Authorization: Bearer $tok" \
        "https://chatgpt.com/backend-api/codex/models?client_version=${ver:-0}" 2>/dev/null)
  case "$code" in
    200) echo "AUTH: ok (server accepted stored token, exp in $(( (${exp:-0}-now)/3600 ))h)" >&2; return 0 ;;
    401|403)
      if [ -n "$exp" ] && [ "$exp" -le "$now" ] 2>/dev/null; then
        echo "AUTH: stored access_token 已过期（$(( (now-exp)/3600 ))h 前）；真调用会尝试 refresh——不判死" >&2
        return 3
      fi
      echo "AUTH: 服务端拒绝未过期的 token（HTTP ${code}）——凭据已失效" >&2; return 2 ;;
    *)
      echo "AUTH: curl 探针判不出（HTTP '${code:-000}'），改问 codex doctor 的 websocket 握手" >&2
      local ws
      ws=$(codex doctor --json 2>/dev/null | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["checks"]["network.websocket_reachability"]["status"])
except Exception: print("unknown")' 2>/dev/null)
      case "$ws" in
        ok) echo "AUTH: ok (codex doctor websocket 握手成功)" >&2; return 0 ;;
        *)  echo "AUTH: websocket 握手状态='${ws}'——判不出" >&2; return 3 ;;
      esac ;;
  esac
}

if [ "$MODE" = auth ]; then
  auth_probe; rc=$?
  case "$rc" in
    0) echo "OK: codex auth verified against server"; exit 0 ;;
    2) echo "ERROR: codex 认证失效——跑 codex login" >&2; exit 67 ;;
    *) echo "ERROR: codex 认证**无法验证**（非拒绝）——按不可用处理（fail-closed，不静默放行）" >&2; exit 65 ;;
  esac
fi

# ══ 模型解析：读 codex 自带目录，挑"可见且支持目标 effort 档、priority 最小"的 ═══
# codex 无 --list-models；`codex debug models` 输出 models[]（slug / visibility /
# priority / supported_reasoning_levels）。priority 由服务端下发，1=最强（启发式，非承诺）。
# ⚠️ 它**不是**可用性信号：实测断网 exit 0（读 ~/.codex/models_cache.json 缓存）、
#    换个空 CODEX_HOME 也 exit 0 但返回**另一份内置目录**（多出 gpt-5.4 / gpt-daybreak-*）。
#    所以解析永远成功 ⇒ 解析成功**不许**被 doctor 当成 HEALTHY 的依据。
EFFORT="${SURVEY_CODEX_EFFORT:-xhigh}"
case "$EFFORT" in
  low|medium|high|xhigh) ;;
  *) echo "WARN: SURVEY_CODEX_EFFORT='${EFFORT}' 非法（low|medium|high|xhigh），回落 xhigh" >&2; EFFORT=xhigh ;;
esac

MODEL=""; MODEL_SRC=""
if [ -n "${SURVEY_CODEX_MODEL:-}" ]; then
  case "$SURVEY_CODEX_MODEL" in
    *[!A-Za-z0-9._-]*) echo "WARN: SURVEY_CODEX_MODEL 含非法字符，忽略，改用自动解析" >&2 ;;
    *) MODEL="$SURVEY_CODEX_MODEL"; MODEL_SRC=pinned ;;
  esac
fi

CATALOG_AGE=-1
CACHE_FILE="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
if [ -r "$CACHE_FILE" ]; then
  CATALOG_AGE=$(python3 - "$CACHE_FILE" <<'PY' 2>/dev/null || echo -1
import json,sys,time,datetime
try:
    t=json.load(open(sys.argv[1]))["fetched_at"].replace("Z","+00:00")
    print(int(time.time()-datetime.datetime.fromisoformat(t).timestamp()))
except Exception: print(-1)
PY
)
fi

CAT_FILE=$(mktemp "${TMPDIR:-/tmp}/survey-codex-models.XXXXXX")
CAT_ERR="$CAT_FILE.err"
if run_with_deadline 20 "$CAT_FILE" "$CAT_ERR" -- codex debug models && [ -s "$CAT_FILE" ]; then
  CATALOG_OK=1
else
  CATALOG_OK=0
  echo "WARN: codex debug models 失败/超时（>20s）——无法核对模型目录" >&2
fi

if [ -z "$MODEL" ] && [ "$CATALOG_OK" -eq 1 ]; then
  MODEL=$(python3 - "$CAT_FILE" "$EFFORT" <<'PY' 2>/dev/null
import json,sys
try: ms=json.load(open(sys.argv[1]))["models"]
except Exception: sys.exit(0)
want=sys.argv[2]
c=[m for m in ms
   if m.get("visibility")=="list"
   and any(e.get("effort")==want for e in m.get("supported_reasoning_levels",[]))
   and "codex" not in m.get("slug","")        # 编码专用，排除（与 cursor 侧 -codex 通排一致）
   and not any(k in m.get("slug","") for k in ("mini","nano","lite","spark","preview"))]
if c: print(sorted(c,key=lambda m:(m.get("priority",10**6),m["slug"]))[0]["slug"])
PY
)
  [ -n "$MODEL" ] && MODEL_SRC=catalog
fi

if [ -z "$MODEL" ]; then
  MODEL="$FALLBACK_MODEL"; MODEL_SRC=fallback
  echo "WARN: 未从目录解析到可用模型，回落到 $MODEL" >&2
fi

# 存在性复核（与 doctor L3 对 cursor 侧做的事同构）：钉值/fallback 都可能指向已下架 id。
# codex 对未知 id 的行为更坑——它**先本地降级**("Model metadata for `X` not found.
# Defaulting to fallback metadata")再被服务端 400 打回，不复核就会白烧一次调用
if [ "$CATALOG_OK" -eq 1 ] && ! python3 -c '
import json,sys
print("Y" if any(m.get("slug")==sys.argv[2] for m in json.load(open(sys.argv[1]))["models"]) else "N")' \
    "$CAT_FILE" "$MODEL" 2>/dev/null | grep -q Y; then
  echo "WARN: ${MODEL_SRC} 模型 ${MODEL} 不在 codex 目录中——正式调用大概率 400" >&2
  MODEL_SRC="${MODEL_SRC}-unlisted"
fi
rm -f "$CAT_FILE" "$CAT_ERR"

if [ "$CATALOG_AGE" -ge 0 ] && [ "$CATALOG_AGE" -gt "$CATALOG_TTL" ]; then
  echo "WARN: 模型目录缓存已 $(( CATALOG_AGE / 3600 ))h 未刷新（>${CATALOG_TTL}s），解析结果可能过时" >&2
  MODEL_SRC="${MODEL_SRC}-stale"
fi

printf 'MODEL: %s (family=codex src=%s effort=%s catalog_age=%ss)\n' \
       "$MODEL" "$MODEL_SRC" "$EFFORT" "$CATALOG_AGE" >&2
# 让 doctor 无法把"解析成功"误当成"通道健康"：解析路径**明说**自己没验认证
echo "AUTH: unverified (run --auth-check; 目录解析在断网/未登录下同样成功)" >&2

if [ "$MODE" = resolve ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# 目录里没有这个 id → 别烧那一次必 400 的调用（fail-closed）
case "$MODEL_SRC" in
  *-unlisted*) echo "ERROR: [codex] 模型 ${MODEL} 不在目录中，跳过调用（钉值请改 SURVEY_CODEX_MODEL，或更新 FALLBACK_MODEL）" >&2; exit 65 ;;
esac

# ══ 正式调用 ═══════════════════════════════════════════════════════════
TIMEOUT_SEC=$(validate_seconds "${SURVEY_TIMEOUT_SEC:-570}" 5 7200 570 SURVEY_TIMEOUT_SEC)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/survey-codex.XXXXXX")
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "ERROR: mktemp 失败" >&2; exit 65; }
trap 'rm -rf "$WORK"' EXIT
EVENTS="$WORK/events.jsonl"; ERR_LOG="$WORK/stderr.log"
RUN_CWD="$WORK/cwd"; mkdir -p "$RUN_CWD"     # 空目录：不让被调研仓库的 AGENTS.md / git 信息漏进 lens

rm -f "$OUTPUT_FILE"                          # 失败时 -o 不会创建文件；不清旧文件会把上一轮残留当本轮成果

# flag 逐条理由（都经 2026-09-09 本机实测，别凭印象删）：
#   --ignore-user-config  用户 ~/.codex/config.toml 里有 notify=[GUI app,"turn-ended"]（每轮
#                         弹 macOS 界面）、MCP server（其一 `npx -y ...` 每次现下包）、十几个 plugin。
#                         全部与调研无关且拖慢/污染。**代价**：连 model / model_reasoning_effort
#                         一起丢掉，且丢掉后 effort 默认变成 `none`（实测 header 打印
#                         "reasoning effort: none"）——静默降级，所以 -m 与 effort 必须显式补回
#   -m / -c model_reasoning_effort  补回上面丢掉的两项，并让模型**可复现**（不随用户改配置漂移）
#   -c tools.web_search=true     搜索是 X 眼存在的理由；`--strict-config` 验过该 key 合法。
#                                注意顶层 `codex --search` 在 exec 子命令上**不存在**（实测报错）
#   -c skills.include_instructions=false
#                         codex 会加载 ~/.agents/skills（**不在** CODEX_HOME 下，--ignore-user-config
#                         挡不住）。`codex debug prompt-input` 实测：默认预置 prompt 26,635 B，
#                         <skills_instructions> 占 13,356 B；关掉后 18,153 B
#   --disable apps        再砍掉 <recommended_plugins>（5,786 B 插件广告）→ 14,612 B
#   --ephemeral           不落盘会话（多窗并发跑 survey 时不互相污染 session 历史）
#   -s read-only / -C 空目录  lens 只该读网、不该碰盘；shell 内网络也被沙箱拦（web_search 工具不受影响）
#   --color never         防 ANSI 序列混进 -o / 事件流
#   --json + -o           **分流**：stdout=事件流(做失败分类)、-o=最后一条消息(正文)。
#                         开了 --json 之后 stdout 就不是正文了，不能只靠 stdout
#   -  < "$PROMPT_FILE"   prompt 走 stdin，绕开 ARG_MAX。**必须**用 `-`：把 prompt 当位置参数、
#                         同时 stdin 又是管道时，codex 会打 "Reading additional input from stdin..."
#                         并挂住等 EOF（实测挂了 3 分钟）
run_with_deadline "$TIMEOUT_SEC" "$EVENTS" "$ERR_LOG" -- \
  codex exec \
    --ignore-user-config --ignore-rules \
    --ephemeral --skip-git-repo-check --color never \
    -C "$RUN_CWD" -s read-only \
    -m "$MODEL" \
    -c model_reasoning_effort="$EFFORT" \
    -c tools.web_search=true \
    -c skills.include_instructions=false \
    --disable apps \
    --json -o "$OUTPUT_FILE" \
    - < "$PROMPT_FILE"
EXIT=$?

if [ "$EXIT" -eq 124 ] || [ "$EXIT" -eq 137 ]; then
  echo "ERROR: codex timeout (>${TIMEOUT_SEC}s)" >&2
  exit 124
fi

# codex exec 的 usage error（clap）是 2。走到这里说明**本脚本**拼了一条它不认的命令行
# ——多半是 codex 升级改了 flag 契约。这不是降级场景，必须 fail-loud 让人改脚本
if [ "$EXIT" -eq 2 ]; then
  echo "ERROR: codex 拒绝命令行（exit 2）——codex CLI flag 契约变了，run-codex.sh 需要更新" >&2
  sed -n '1,5p' "$ERR_LOG" >&2
  exit 64
fi

# 失败分类：**只看事件流**。实测 401 认证 / 400 模型不存在 / 配额墙 全部 exit 1
FAILMSG=$(python3 - "$EVENTS" <<'PY' 2>/dev/null
import json,sys
msgs=[]
for line in open(sys.argv[1], errors="replace"):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get("type")=="turn.failed": msgs.append((d.get("error") or {}).get("message",""))
    elif d.get("type")=="error":     msgs.append(d.get("message",""))
print("\n".join(m for m in msgs if m))
PY
)
[ -n "$FAILMSG" ] || FAILMSG=$(tail -20 "$ERR_LOG" 2>/dev/null)

if [ "$EXIT" -ne 0 ]; then
  # 顺序与 cursor 版一致：额度 → 认证 → 其它。修复动作完全不同，混号会把人指错方向。
  # 额度判据锚定 codex 二进制里的用户可见文案（strings 提取）：
  #   "You've hit your usage limit[ for| .]" / "Upgrade to Plus|Pro to continue using Codex"
  #   "purchase more credits" / "rate limit exceeded: " / 枚举 usage_limit_reached / credits_depleted
  # ⚠️ **本机未真实撞过墙**（订阅未耗尽）。以上是"文案来源可查"的推断，不是实测确认；
  #    真撞墙那次必须回来核对：把 turn.failed.error.message 原文钉进这里
  #    （探测：codex exec --json --ephemeral --skip-git-repo-check -s read-only -o /tmp/q.out - <<< hi）
  if printf '%s' "$FAILMSG" | grep -qiE "hit your usage limit|usage limit reached|usage_limit_reached|credits_depleted|credits depleted|purchase more credits|rate limit exceeded|upgrade to (plus|pro) to continue using codex"; then
    record_quota_block "$LENS" "$FAILMSG"
    echo "ERROR: [codex] 撞到 ChatGPT 订阅用量上限——不是认证问题、也不是超时" >&2
    printf '%s\n' "$FAILMSG" | head -3 | sed 's/^/       /' >&2
    echo "       codex 通道本窗口不可用（按小时/周滚动重置，非月度）。主评审按替补链换 grok；X1 走 PARTIAL。" >&2
    echo "       余量看 codex TUI 的 /status；或到 https://chatgpt.com/codex/settings/usage" >&2
    exit 68
  fi
  if printf '%s' "$FAILMSG" | grep -qiE "access token could not be refreshed|log out and sign in again|token_expired|could not validate your token|could not parse your authentication token|unauthorized|\"status\":401"; then
    echo "ERROR: [codex] 认证失效——跑 codex login" >&2
    printf '%s\n' "$FAILMSG" | head -3 | sed 's/^/       /' >&2
    exit 67
  fi
  echo "ERROR: codex exited $EXIT" >&2
  printf '%s\n' "$FAILMSG" | tail -10 | sed 's/^/       /' >&2
  exit 65
fi

# 实测：任何失败路径下 -o 文件**根本不会被创建**（不是创建了空文件），所以判据要
# 同时覆盖"不存在"与"为空"
if [ ! -s "$OUTPUT_FILE" ]; then
  echo "ERROR: codex returned empty output (exit 0 但 -o 无内容)" >&2
  exit 66
fi

# 结构校验（缺段 = 按 exit 66 降级，与 cursor 侧同一条规矩）
if ! check_required_sections "$OUTPUT_FILE"; then
  echo "ERROR: codex 输出缺少约定段落——按空输出处理（截断/跑题的输出被当成功用，比失败更糟）" >&2
  exit 66
fi

clear_quota_block "$LENS"
echo "OK: codex ($MODEL, effort=$EFFORT) wrote $(wc -c < "$OUTPUT_FILE" | tr -d ' ') bytes to $OUTPUT_FILE"
exit 0
