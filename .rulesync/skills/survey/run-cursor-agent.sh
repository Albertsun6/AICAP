#!/usr/bin/env bash
# /survey skill — cursor-agent invocation helper（gpt / gemini / grok 三族）
#
# 被主 Claude 调用跑一次异构 lens。**没有 opt-out flag**——/survey 只有一条高质量路径，
# 异构搜索 + 终审始终执行，不可用时自动降级。模型**每次运行时自动解析成当前账号可用的
# 最新最强**（见下方 §模型选择 / pick_strongest），不钉死版本号。失败时优雅退出，让主
# Claude 加 banner 并降级。
#
# 2026-11-19 起三族都走本脚本：gpt 族 2026-09-09 曾因"OpenAI 将于 11-12 切断 Cursor"的公告
#    从这里退役、改走 run-codex.sh；11-19 实测 Cursor 侧 gpt-5.6-* 仍可列出并可调用，遂恢复。
#    run-codex.sh 保留为**可选备用通道**（与 gpt 同族），默认流程不再依赖它。
#
# 用法：
#   bash run-cursor-agent.sh <prompt-file> <output-file> <gpt|gemini|grok>
#   bash run-cursor-agent.sh --resolve-only <gpt|gemini|grok>   # 只解析模型不调用（供 doctor.sh 自检）
#
# 参数：
#   <prompt-file>  : 已含完整 prompt 的文件路径（主 Claude 负责拼装）
#   <output-file>  : cursor-agent 输出落盘路径
#   <family>       : gpt | gemini | grok（**必须显式给**，没有默认族）。
#                    gpt = Phase 2 X1 + Phase 6 主评审；gemini = Phase 2 X2 + 事实 tiebreaker；
#                    grok = Phase 6 红队 + 替补族
#   --resolve-only : 走完与正式调用完全相同的模型解析（含 SURVEY_CURSOR_MODEL 校验、
#                    列表 fetch deadline、fallback 回落 + WARN），把裸模型 id 打到
#                    stdout 后 exit 0，不消耗配额。doctor 靠它复用生产逻辑，杜绝两处漂移
#
# 环境变量：
#   SURVEY_CURSOR_EFFORT=high|xhigh   effort 档偏好，三族都生效（缺省 xhigh）
#   SURVEY_CURSOR_MODEL=<id>          钉模型（前缀必须匹配 family，否则忽略回自动解析）
#   SURVEY_SERIES_GPT / SURVEY_SERIES_GEMINI='<系列> <系列> ...'
#                                     同版本内的系列优先顺序（靠前的强），覆盖排名文件，见 §模型选择。
#                                     空格或逗号分隔；写了排名文件里没核实过的系列名会打 WARN（多半是拼错）
#   SURVEY_RANKING_FILE=<路径>        排名文件位置（缺省 <本目录>/model-ranking.conf；测试用）
#   SURVEY_MODEL_LIST_SNAPSHOT=<路径> 仅 --resolve-only：用这份已取到的模型列表，不再请求（doctor.sh 用）
#   SURVEY_TIMEOUT_SEC=<秒>           内层 watchdog，缺省 570；async 由 runner 传入
#   SURVEY_REQUIRE_SECTIONS='## A|## B'  `|` 分隔的必含段落；缺段按 exit 66
#
# Exit codes（与 run-codex.sh 同一张表）：
#   0   成功，<output-file> 已写入有效内容
#   64  参数错（含非法族、prompt 文件不存在）—— 主 Claude 修正调用，不是降级场景
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
    echo "Usage: $0 --resolve-only <gpt|gemini|grok>" >&2
    exit 64
  fi
  PROMPT_FILE=""
  OUTPUT_FILE=""
  FAMILY="$1"
else
  if [ $# -ne 3 ]; then
    echo "Usage: $0 <prompt-file> <output-file> <gpt|gemini|grok>" >&2
    exit 64
  fi
  PROMPT_FILE="$1"
  OUTPUT_FILE="$2"
  FAMILY="$3"
fi

case "$FAMILY" in
  gpt|gemini|grok) ;;
  *) echo "ERROR: 未知模型家族 '$FAMILY'（可选 gpt | gemini | grok）" >&2; exit 64 ;;
esac

if [ "$RESOLVE_ONLY" -eq 0 ] && [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 64       # 参数错：修正调用路径后重跑，不是"模型返回空输出"（66），不许按降级处理
fi

command -v cursor-agent >/dev/null 2>&1 || {
  echo "ERROR: cursor-agent not in PATH" >&2
  echo "Install: curl https://cursor.com/install -fsS | bash（或 Cursor → Settings → CLI tools）" >&2
  exit 69
}

# ── 模型选择：不钉版本，运行时跟该族最新最强 ──────────────────────────
# 规则（每次跑 cursor-agent --list-models 解析，~1s）。id 按 "<前缀><版本>[-<系列>][-<档位>]" 解析：
#   前缀  ：gpt = gpt-；gemini = gemini-；grok = grok- 或 cursor-grok-（2026-11 起最新的 grok-4.7
#           不带 cursor- 前缀，旧的 4.6/4.5 仍带）
#   版本  ：点号分隔；连字符写法（gpt-5-7-sol / grok-4-8：紧跟主版本的 1 到 2 位纯数字段，最多两段）
#           与点号写法等价，NEW-MODEL 提示与 verified 都按点号写法算
#   档位  ：只收 -high / -xhigh（-extra-high 视同 xhigh）；gpt、grok 必须带档
#   gemini：主版本 ≥ 4 必须带系列名 + high/xhigh 档（gemini-4-neon-xhigh）；主版本 < 4 沿用旧规则
#           （名字里有完整的 -pro 段、可无档位，如 gemini-3.1-pro）。版本优先，所以 Gemini 4 在列表里就必胜 3.1-pro
#   系列  ：同版本内按"优先顺序"排，靠前的强 > 无系列的裸旗舰 > 不在顺序里的系列（彼此按档位、
#           列表先后）。已知系列后面多一段变体（sol-1m）顺位紧跟在同系列正牌之后：低于正牌
#           （不论列表先后与档位），高于下一档系列。顺序来源依次为：
#             ① 环境变量 SURVEY_SERIES_GPT / SURVEY_SERIES_GEMINI（空格分隔，单次覆盖）
#             ② 排名文件 model-ranking.conf 里该族的 series 行——上网查证后的结论，带依据 URL 与核对日期
#             ③ 排名文件缺失或读不出该族的 verified 清单 → 脚本内保底顺序 + WARN
#                （gpt "sol terra luna" / gemini "neon carbon hydrogen argon"；保底只为不中断，不代表查过）
#   新模型：**在全部筛选之前**检测——筛选只决定选不选，不决定提不提示。该族每个 id 去掉 -fast /
#           档位后缀（-preview / -exp 也去掉）得到「版本[-系列]」，不在排名文件该族的 verified 清单里
#           → stderr 打一行 `NEW-MODEL: [族] <名字> 未在排名文件中核实…`（每个名字一行，写明本次选没
#           选用；钉值生效时写的是钉值的实际情况）。版本低于最高版本、又被筛掉的名字同样提示。
#           所以裸 id / 只有 -max 或低档 / -preview 首发的下一代模型也会提示（选型规则不收它们，
#           提示里写「形态不在选型规则内」）。小模型与专用形态（-mini -codex -flash…）只在版本
#           超过最高版本时提示。
#           名字里有族名但形态认不出来的（xai-grok-5 / gpt6 / grok-code-5）也提示。核实后把提示里
#           的名字原样写进 verified 即可消掉（带族前缀的 gpt-6.2-astra / grok-4.8 与去前缀的
#           6.2-astra / 4.8 两种写法都认）。**盲区**：名字里连族名都没有的（如 OpenAI 的 o5）
#           脚本无从判断，靠 60 天复查覆盖（见 model-ranking.conf 文件头）。
#           选型不因提示改变：版本更高的新候选照样胜出（不许因为没核实就继续用旧版本）；同版本的
#           新系列不在顺序里，排在已核实系列之后。看到 NEW-MODEL 就该上网核实并更新排名文件
#           （SKILL.md 硬约束）。
#   文件自检：键名 / 段名 / 值不分大小写；series / verified / checked 的行尾注释（空白 + #）会剥掉；
#           不认识的键、同一版本核实了两个以上名字而其中的系列不在 series 顺序里、
#           verified 带系列却没有 series 行 → 各打一行 `WARN: [族] 排名文件 …`（doctor 汇总）
#   全族通排：-fast（插队计费，中段也算）/ -none -low -medium -minimal（低档）/ -max（太慢，必超时）/
#            -codex -mini -nano -lite -flash（小或专用）/ -preview -exp -experimental -realtime -audio
#            -image -embed -tts
#   ⚠️ 排除项按完整分段匹配（-名字 后面是 - 或行尾）：裸 /mini/ 会把 ge-MINI 整族误杀（实测踩过），
#      /-mini/ 会误杀 gpt-6-minimal
#   比较：主版本 → 次版本 → 修订号 → 系列顺位 → 档位匹配度（偏好档 > 另一档）→ 列表先出现者
# 取列表失败 / 超时 / 无候选 → 回落到该族 FALLBACK（打 WARN）。认证失效**不回落**，exit 67。
# 列表疑似临时缩水（见 SHRUNK_LIST_MAX_LINES）→ 不选型，run 模式 exit 65。
case "$FAMILY" in                      # 各族 fallback：2026-11-19 复核均在实时列表
  gpt)    FALLBACK_MODEL="gpt-5.6-sol-high" ;;    # 2026-11-19 实测：联网搜索任务约 4 分钟
  gemini) FALLBACK_MODEL="gemini-4-neon-high" ;;
  grok)   FALLBACK_MODEL="grok-4.7-high" ;;
esac
# 列表缩水判据：Cursor 的模型列表会临时缩水到约 40 行（只剩 Grok/Kimi/GLM/DeepSeek/Composer），
# 不到一小时恢复（2026-11 多次实测）；完整列表 2026-08-30 实测 206 行、2026-11-19 实测 288 行。
# 取两者之间的 100：非空行数低于它 → 判"疑似临时缩水"，**一律不选型**（钉值也不放行）：缩水列表里
# 剩下的多半是旧型号，照常选会悄悄跑在上上代模型上。run 模式 exit 65；--resolve-only 仍 exit 0
# 打回落 id（doctor 靠 stderr 的"疑似临时缩水"识别）。
SHRUNK_LIST_MAX_LINES=100
LIST_DEADLINE=20                     # 取模型列表的独立超时（秒）

# 额度错误的判据。锚定 2026-08-30 实测原文（cursor-agent 2026.08.25-3e8eec8）：
#   ActionRequiredError: You've hit your usage limit You've saved $NNN on API model
#   usage this month with <plan>. Switch to a different model or set a Spend Limit to
#   continue with this model. Your usage limits will reset when your monthly cycle
#   ends on 1/31/2099.
# 故意不匹配裸 "rate limit"——那是短时限流，重试即可，与月度额度耗尽是两回事
is_quota_error() { grep -qiE "hit your usage limit|ActionRequiredError|Spend Limit|usage limits will reset" "$1" 2>/dev/null; }

# 认证失效的判据：取列表与正式调用共用一份，并与 doctor.sh L2 的写法对齐
# （含 401 Unauthorized / Forbidden——少了它们，--resolve-only 会回落并 exit 0，把 auth 故障洗成解析成功）
is_auth_error() { grep -qiE "authentication required|authentication failed|stored authentication is invalid|invalid or expired|unauthoriz|forbidden|agent login|CURSOR_API_KEY" "$1" 2>/dev/null; }

# 取模型列表：写进 $1；返回 0=成功 / 2=认证失效 / 1=超时或其它失败
# （**不接受**"非零退出但有部分输出"）。stderr 落 <$1>.err 不丢弃：凭据过期时这行 stderr
# 是 "Error: Authentication required"——唯一能定位根因的证据（2026-08-30 实测）
fetch_model_list() {
  local out="$1" err="$1.err" rc
  # doctor.sh 专用：它在 L2 已经取过一次实时列表，L3 的三次 --resolve-only 直接用那份快照，
  # 保证"解析"与"存在性复核"看的是同一份列表。只在 --resolve-only 下生效——正式调用必须自己取
  if [ "$RESOLVE_ONLY" -eq 1 ] && [ -s "${SURVEY_MODEL_LIST_SNAPSHOT:-}" ]; then
    cat "$SURVEY_MODEL_LIST_SNAPSHOT" > "$out"; : > "$err"
    return 0
  fi
  run_with_deadline "$LIST_DEADLINE" "$out" "$err" -- cursor-agent --list-models
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  is_auth_error "$err" && return 2
  return 1
}

# 从列表里挑该族最强候选（全程单个 awk：不用 sort|head，避免 SIGPIPE / locale 依赖）
# 用法：pick_strongest <gpt|gemini|grok> [xhigh|high] [钉值 id] < <模型列表>
# 第二参 = effort 档**偏好**（缺省 xhigh）：版本与系列优先，同版本同系列内先挑偏好档、
# 该档没货自动落到另一档（可用性优先，不因档位缺货而整族失败）。
# 第三参 = 已生效的钉值（可空）：只影响 NEW-MODEL 行里「本次已选用 / 未选用」的措辞，不影响 stdout。
# 系列顺序与已核实清单在函数内读（环境变量 + 排名文件）：test-model-selection.sh 只 eval
# 这一个函数体，不能依赖函数外的变量（SKILL_DIR 例外：缺了就要求给 SURVEY_RANKING_FILE）。
pick_strongest() {
  local order="" ovar="" rf="${SURVEY_RANKING_FILE:-${SKILL_DIR:-.}/model-ranking.conf}" rfok=1
  # 排名文件必须是可读的普通文件：指向目录时 BSD awk 的 getline 直接报 i/o error 退出（选型整个失败），
  # 按「缺失或读不出」走保底顺序
  { [ -f "$rf" ] && [ -r "$rf" ]; } || rfok=0
  case "$1" in
    gpt)    order="${SURVEY_SERIES_GPT:-}";    ovar=SURVEY_SERIES_GPT ;;
    gemini) order="${SURVEY_SERIES_GEMINI:-}"; ovar=SURVEY_SERIES_GEMINI ;;
  esac
  awk -v fam="$1" -v pref="${2:-xhigh}" -v pin="${3:-}" -v order="$order" -v ovar="$ovar" -v rf="$rf" -v rfok="$rfok" '
    # 版本号按段比较（a > b 返回 1，相等 0，小于 -1）；只比前三段
    function vcmp(a, b,   x, y, i, d) {
      split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= 3; i++) { d = (x[i] + 0) - (y[i] + 0); if (d != 0) return d > 0 ? 1 : -1 }
      return 0
    }
    # 连字符写的版本号（gpt-5-7-sol / gemini-4-5-neon / grok-4-8）与点号写法等价：紧跟主版本的
    # 1 到 2 位纯数字段（最多两段）并入次版本 / 修订号。gemini-4-neon（不是数字）、8 位日期段、
    # 已带点号的版本（5.6-...）都不动
    function dotver(s,   h, t, e) {
      if (!match(s, /^[0-9]+-[0-9][0-9]?(-[0-9][0-9]?)?(-|$)/)) return s
      h = substr(s, 1, RLENGTH); t = substr(s, RLENGTH + 1)
      e = (h ~ /-$/); if (e) h = substr(h, 1, length(h) - 1)
      gsub(/-/, ".", h)
      return h (e ? "-" : "") t
    }
    # 记一个未核实的名字（每个名字只记一次）；odd=1 表示命名形态认不出来
    function note_new(key, id, odd) {
      if (key in seen) return
      seen[key] = 1; nnew++; newkey[nnew] = key; newid[nnew] = id; newodd[nnew] = odd
    }
    BEGIN {
      bmaj = -1; bmin = -1; bpat = -1; bser = -1; btier = -1; best = ""; bkey = ""
      if (fam != "gpt" && fam != "gemini" && fam != "grok") exit 1
      # ── 排名文件：取本族的 series 与 verified（格式见 model-ranking.conf 文件头）──
      # 键名、段名、值一律转小写再比：model id 全是小写，文件里写成 Series = Neon 不该悄悄失效
      sec = ""; ranked = 0; fseries = ""; nnew = 0; maxver = ""
      while (rfok && (getline line < rf) > 0) {
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
        line = tolower(line)
        if (line ~ /^[ \t]*\[/) { sec = line; gsub(/[^a-z]/, "", sec); continue }
        if (sec != fam) continue
        eq = index(line, "=")
        k = (eq == 0) ? line : substr(line, 1, eq - 1); v = (eq == 0) ? "" : substr(line, eq + 1)
        gsub(/[ \t]/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
        # 行尾注释（# 前有空白，或值整个是注释）要剥掉：不剥的话注释里的系列名会改掉顺位，
        # 注释里的数字会被当成已核实的版本、抬高 maxver 吞掉 NEW-MODEL。evidence 是 URL，可能带 #fragment，不剥
        if (k != "evidence") sub(/(^|[ \t]+)#.*$/, "", v)
        if (eq > 0 && k == "series") fseries = v
        else if (eq > 0 && k == "verified") {
          if (v == "") continue
          ranked = 1
          nv = split(v, vv, " ")
          for (i = 1; i <= nv; i++) {
            t = vv[i]; known[t] = 1
            # 带族前缀的写法也认：NEW-MODEL 提示打的就是 gpt-6.2-astra / grok-4.8，照抄进来必须能消掉提示。
            # 只在前缀后面紧跟数字时才剥，认不出形态的名字（grok-code-5）保持原样
            if (fam == "grok" && t ~ /^cursor-grok-[0-9]/) t = substr(t, 13)
            else if (index(t, fam "-") == 1 && substr(t, length(fam) + 2, 1) ~ /[0-9]/) t = substr(t, length(fam) + 2)
            t = dotver(t); known[t] = 1
            dash = index(t, "-")
            kv = dash ? substr(t, 1, dash - 1) : t
            if (kv !~ /^[0-9]+(\.[0-9]+)*$/) continue      # 认不出形态的名字（见下）没有版本可比
            if (maxver == "" || vcmp(kv, maxver) > 0) maxver = kv
            # 每个版本下已核实了几个名字（无系列的裸名也算一个，系列记成空串）
            ks = dash ? substr(t, dash + 1) : ""
            if (!((kv, ks) in vser)) { vser[kv, ks] = 1; vcnt[kv]++ }
            if (ks != "") { sub(/-.*$/, "", ks); vsname[ks] = 1 }
          }
        }
        else if (eq > 0 && (k == "checked" || k == "evidence")) continue
        else print "WARN: [" fam "] 排名文件 " rf " 里有不认识的行「" k "」，已忽略（认识的键：checked / series / verified / evidence，拼错了？）" > "/dev/stderr"
      }
      close(rf)
      if (!ranked) {
        # 措辞避开"回落到"三个字：doctor 用它识别模型 fallback，这里只是顺序保底
        print "WARN: [" fam "] 排名文件 " rf " 缺失或读不出该族的 verified 清单——系列顺序改用脚本内保底顺序，新模型检测本次跳过" > "/dev/stderr"
        fseries = (fam == "gpt") ? "sol terra luna" : ((fam == "gemini") ? "neon carbon hydrogen argon" : "")
      } else {
        # 自检：verified 里同一版本有两个以上名字（含无系列的裸名）时，带系列的都得出现在 series
        # 顺序里，否则顺位是 0，会悄悄排到最后（键名拼错 / 系列名拼错都落到这里）。
        # 顺位按系列的第一段查，所以这里也按第一段比
        nf = split(fseries, fs, " "); for (i = 1; i <= nf; i++) inser[fs[i]] = 1
        miss = ""
        for (ck in vser) {
          split(ck, cp, SUBSEP)
          s1 = cp[2]; sub(/-.*$/, "", s1)
          if (s1 != "" && vcnt[cp[1]] >= 2 && !(s1 in inser)) miss = miss " " cp[2]
        }
        if (miss != "" && fseries == "") {
          print "WARN: [" fam "] 排名文件 " rf " 的 verified 清单带系列，却没读到 series 行（键名拼错？）——系列顺序改用脚本内保底顺序" > "/dev/stderr"
          fseries = (fam == "gpt") ? "sol terra luna" : ((fam == "gemini") ? "neon carbon hydrogen argon" : "")
        } else if (miss != "")
          print "WARN: [" fam "] 排名文件 " rf " 的 verified 清单里有系列不在 series 顺序里:" miss "（拼写？）——它们排在已列出的系列之后" > "/dev/stderr"
      }
      envord = (order != "")
      if (envord) gsub(/,/, " ", order)                  # 环境变量里手敲逗号分隔也认
      else order = fseries
      # 系列顺位：靠前的分高（偶数，≥4）；它的变体（sol-1m）低一分（奇数，≥3），仍高于下一档系列；
      # 无系列的裸旗舰 = 1；未列入顺序的系列 = 0（见下方 ser）
      no = split(tolower(order), ord, " ")
      for (i = 1; i <= no; i++) {
        if (ord[i] in srank) {                           # 重复的名字以第一次出现为准，不许后写覆盖先写
          print "WARN: [" fam "] 系列顺序里「" ord[i] "」重复出现（来源：" (envord ? ovar : "排名文件 " rf " 的 series 行") "），以第一次出现的位置为准" > "/dev/stderr"
          continue
        }
        srank[ord[i]] = 2 * (no - i) + 4
        # 环境变量是手敲的：拼错一个词，那个系列的顺位就悄悄变成 0
        if (envord && ranked && !(ord[i] in vsname))
          print "WARN: [" fam "] " ovar " 里的「" ord[i] "」不是排名文件里已核实的系列（拼写？）——仍按所给顺序处理" > "/dev/stderr"
      }
    }
    /^[a-z0-9]/ && index($0, " - ") > 0 {
      id = $1
      # ── 前缀（grok 两种写法都收；先试长的）──
      pfx = 1
      if (fam == "gpt" && id ~ /^gpt-/)                   rest = substr(id, 5)
      else if (fam == "gemini" && id ~ /^gemini-/)        rest = substr(id, 8)
      else if (fam == "grok" && id ~ /^cursor-grok-/)     rest = substr(id, 13)
      else if (fam == "grok" && id ~ /^grok-/)            rest = substr(id, 6)
      else { pfx = 0; rest = id }
      if (pfx) rest = dotver(rest)
      # ── 新模型检测：排在全部筛选之前。筛选只决定「选不选」，不许顺带决定「提不提示」──
      # 下一代模型常以选型规则不收的形态首发（裸 id / 只有 -max 或低档 / -preview / 换前缀）
      if (!pfx && index(id, fam) == 0) next               # 别族的 id
      # 预览版 / 实验版与正式版算同一个名字；-fast 不论在末尾还是中段（grok-5-fast-high）都不算名字的
      # 一部分。先去这些段再剥档位：-preview 排在档位后面时（gpt-5.6-sol-high-preview）档位才剥得掉
      dstem = rest "-"
      while (sub(/-(preview|exp|experimental|fast)-/, "-", dstem)) ;
      sub(/-$/, "", dstem)
      sub(/-(xhigh|extra-high|high|max|medium|low|none|minimal)$/, "", dstem)
      dver = dstem; sub(/-.*$/, "", dver)
      if (!pfx || dver !~ /^[0-9]+(\.[0-9]+)*$/) {
        # 名字里有族名但形态认不出来（xai-grok-5 / gpt6 / grok-code-5）：无从比较版本，只能提示
        # 名字取整个 id（去档位），核实后原样写进 verified 就不再提示
        stem = id; sub(/-fast$/, "", stem); sub(/-(xhigh|extra-high|high|max|medium|low|none|minimal)$/, "", stem)
        if (id == pin) pinkey[stem] = 1
        if (ranked && !(stem in known)) note_new(stem, id, 1)
        next
      }
      if (id == pin) pinkey[dstem] = 1
      if (ranked && !(dstem in known)) {
        # 小模型 / 专用形态只在版本超过已核实最高版本时提示（gpt-5.4-mini 不是新一代，gpt-7-mini 是）；
        # 其余没核实过的名字不论版本高低都提示——低于最高版本又被筛掉的（gpt-5.5-nova-max）否则完全不可见
        special = (id ~ /-(codex|mini|nano|lite|flash|realtime|audio|image|embed|tts)(-|$)/)
        c = (maxver == "") ? 1 : vcmp(dver, maxver)
        if (c > 0 || !special) note_new(dstem, id, 0)
      }
      # ── 全族通排 ──
      # ⚠️ 一律按**完整分段**匹配（前有 `-`，后面是 `-` 或行尾），不能用裸子串也不能只锚一头：
      #    裸 /mini/ 会把 ge-MINI-* 整族误杀（实测踩过）；/-mini/ 会误杀 gpt-6-minimal；
      #    /-fast$/ 漏掉中段的 grok-5-fast-high
      if (id ~ /-fast(-|$)/) next
      if (id ~ /-none$/ || id ~ /-low$/ || id ~ /-medium$/ || id ~ /-minimal$/ || id ~ /-max$/) next
      if (id ~ /-(codex|mini|nano|lite|flash)(-|$)/) next
      if (id ~ /-(preview|exp|experimental|realtime|audio|image|embed|tts)(-|$)/) next
      # ── <版本>[-<系列>][-<档位>] ──
      np = split(rest, part, "-")
      ver = part[1]
      if (ver !~ /^[0-9]+(\.[0-9]+)*$/) next
      # 档位只认末段；-extra-high 是 xhigh 的另一种写法，占两段，必须先于 -high 判
      is_x = 0; is_h = 0; last = np
      if (np >= 2 && part[np] == "xhigh") { is_x = 1; last = np - 1 }
      else if (np >= 3 && part[np] == "high" && part[np - 1] == "extra") { is_x = 1; last = np - 2 }
      else if (np >= 2 && part[np] == "high") { is_h = 1; last = np - 1 }
      series = ""
      for (i = 2; i <= last; i++) series = series (i > 2 ? "-" : "") part[i]
      # 版本按段比较，不能把点后整体当小数："0.10"+0=0.1 会让 6.0.10 输给 6.0.2
      # （异构评审(GPT)给出的可复现反例）
      n = split(ver, seg, ".")
      vmaj = seg[1] + 0
      vmin = (n >= 2) ? seg[2] + 0 : 0
      vpat = (n >= 3) ? seg[3] + 0 : 0
      # ── 每族白名单（未知形态一律拒）──
      if (fam == "gpt" || fam == "grok") {
        if (!is_x && !is_h) next
      } else if (vmaj >= 4) {                       # gemini 4+：系列名 + 档位
        if (series == "" || (!is_x && !is_h)) next
      } else {                                      # gemini 3.x：pro 线，可无档位
        if (id !~ /-pro(-|$)/) next                 # 分段匹配：裸 /pro/ 会收进 gemini-3.5-proto
      }
      # tier = 与偏好档的匹配度（2=偏好档 1=另一档 0=无档位）
      if (pref == "high") tier = is_h ? 2 : (is_x ? 1 : 0)
      else                tier = is_x ? 2 : (is_h ? 1 : 0)
      # 系列顺位：无系列的裸旗舰（1）高于未列入顺序的系列（0）——grok 族没有 series 行，带后缀的
      # 变体不该与裸旗舰平级。已知系列后面多一段变体（sol-1m / sol-2026-11-01）按第一段取顺位再减一：
      # 低于同系列正牌（不论列表先后与档位），高于下一档系列；
      # 排名文件读进来时转了小写，这里也转
      lser = tolower(series); s1 = lser; sub(/-.*$/, "", s1)
      if (series == "")       ser = 1
      else if (lser in srank) ser = srank[lser]
      else if (s1 in srank)   ser = srank[s1] - 1
      else                    ser = 0
      # 通过全部筛选的候选：版本低于已核实最高版本的未知名字也提示（它可能被选中）
      key = ver (series != "" ? "-" series : "")
      cand[key] = 1
      if (id == pin) pinkey[key] = 1
      if (ranked && !(key in known)) note_new(key, id, 0)
      if (vmaj > bmaj ||
          (vmaj == bmaj && (vmin > bmin ||
          (vmin == bmin && (vpat > bpat ||
          (vpat == bpat && (ser > bser ||
          (ser == bser && tier > btier)))))))) {
        bmaj = vmaj; bmin = vmin; bpat = vpat; bser = ser; btier = tier; best = id; bkey = key
      }
    }
    END {
      for (i = 1; i <= nnew; i++) {
        # 钉值生效时最终用的是钉值，不是自动解析的胜者——措辞必须跟紧随其后的 MODEL: 行对得上
        if (pin != "" && (newkey[i] in pinkey)) how = "本次已选用（SURVEY_CURSOR_MODEL 钉值）"
        else if (newodd[i])             how = "命名形态认不出来，本次未选用"
        else if (newkey[i] == bkey)     how = (pin != "") ? "自动解析会选它，但本次被 SURVEY_CURSOR_MODEL=" pin " 钉住未用" : "本次已选用"
        else if (newkey[i] in cand)     how = "本次未选用"
        else                            how = "形态不在选型规则内，本次未选用"
        # 示例 id 用实际选中的那个：同一个名字下先碰到的可能是被筛掉的（grok-5-fast-high），
        # 后面跟着「本次已选用」就成了假话
        ex = newid[i]
        if (pin != "" && (newkey[i] in pinkey)) ex = pin
        else if (newkey[i] == bkey)             ex = best
        print "NEW-MODEL: [" fam "] " (newodd[i] ? "" : fam "-") newkey[i] " 未在排名文件中核实（实时列表里如 " ex "；" \
              how "）——上网核实后更新 model-ranking.conf" > "/dev/stderr"
      }
      if (best != "") print best
    }
  '
}

# effort 档偏好（三族的自动解析都生效；钉值不受影响）
EFFORT="${SURVEY_CURSOR_EFFORT:-xhigh}"
case "$EFFORT" in
  xhigh|high) ;;
  *) echo "WARN: SURVEY_CURSOR_EFFORT='${EFFORT}' 非法（可选 high | xhigh），回落 xhigh" >&2
     EFFORT=xhigh ;;
esac

MODEL=""
SHRUNK=""         # 列表疑似临时缩水时的说明（非空 = 缩水；run 模式一律 exit 65）
if [ -n "${SURVEY_CURSOR_MODEL:-}" ]; then
  # ① 字符集校验（防控制字符污染日志）；不存在注入风险——$MODEL 是独立 argv
  case "$SURVEY_CURSOR_MODEL" in
    *[!A-Za-z0-9._-]*)
      echo "WARN: SURVEY_CURSOR_MODEL 含非法字符，忽略，改用自动解析" >&2 ;;
    *) MODEL="$SURVEY_CURSOR_MODEL" ;;
  esac
  # ② **必须与 $FAMILY 同族**——这是结构性保证。Phase 6 要求"主评审(gpt) 与
  #    tiebreaker(gemini) 异族"，若主 Claude 把钉给 grok 的值带到 gemini 调用上（export 后
  #    忘了 unset），tiebreaker 就会偷偷跑成 grok（红队自己裁自己的争议）且**没有任何外部迹象**。
  if [ -n "$MODEL" ]; then
    case "$FAMILY:$MODEL" in
      gpt:gpt-* | gemini:gemini-* | grok:grok-* | grok:cursor-grok-*) ;;
      *) echo "WARN: SURVEY_CURSOR_MODEL='${MODEL}' 不属于 family=${FAMILY}（gpt 需 gpt- 开头 / gemini 需 gemini- / grok 需 grok- 或 cursor-grok-），已忽略，改用自动解析" >&2
         MODEL="" ;;
    esac
  fi
fi

LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/survey-models.XXXXXX")
# 清理统一挂在 EXIT，从第一个临时文件落地起就生效（原来 trap 到建工作目录时才装，取列表期间被杀
# 会留下 survey-models.* 两个文件）。被 INT / TERM 打断时先杀掉还在跑的 cursor-agent 进程树再退出：
# 否则它成了孤儿——取列表的那个没人管 deadline，正式调用的那个会把整次模型请求跑完、继续烧额度
WORK=""
cleanup() { rm -f "$LIST_FILE" "$LIST_FILE.err"; [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT
on_signal() { # $1 = 退出码（128 + 信号编号）
  if [ -n "${RUN_WITH_DEADLINE_PID:-}" ]; then
    kill_tree TERM "$RUN_WITH_DEADLINE_PID"; sleep 1; kill_tree KILL "$RUN_WITH_DEADLINE_PID"
  fi
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
fetch_model_list "$LIST_FILE"; LIST_RC=$?
case "$LIST_RC" in
  0) # 先数行数再选型：缩水判据不能只在"该族零候选"时才看（那样缩水后剩一个旧型号就被静默选中）
     LIST_LINES=$(grep -cve '^[[:space:]]*$' "$LIST_FILE")
     if [ "$LIST_LINES" -lt "$SHRUNK_LIST_MAX_LINES" ]; then
       SHRUNK="模型列表疑似临时缩水（仅 ${LIST_LINES} 行，完整列表约 288 行），稍后重试"
       echo "WARN: [$FAMILY] ${SHRUNK}——本次不做选型" >&2
     else
       # 钉了模型也照跑一遍：NEW-MODEL 提示不能因为钉值而消失（钉值正是"一直用老模型"的来路）
       AUTO_MODEL=$(pick_strongest "$FAMILY" "$EFFORT" "$MODEL" < "$LIST_FILE")
       [ -z "$MODEL" ] && MODEL="$AUTO_MODEL"
     fi ;;
  2) # 认证失效**不做**静默回落：回落只会让 --resolve-only exit 0，把 auth 故障洗成
     # "解析成功"，doctor 据此报 HEALTHY，真调用再必挂（全局约束 ⑤ fail-closed）
     echo "ERROR: [$FAMILY] cursor-agent 认证失效——跑 cursor-agent login" >&2
     head -1 "$LIST_FILE.err" >&2 2>/dev/null
     rm -f "$LIST_FILE" "$LIST_FILE.err"
     exit 67 ;;
  *) echo "WARN: 取模型列表失败或超时（>${LIST_DEADLINE}s，非认证原因）" >&2 ;;
esac

NO_CANDIDATE=""   # 列表完整却没有该族候选时的原因说明（下架；缩水见上面的 SHRUNK）
if [ -z "$MODEL" ]; then
  if [ "$LIST_RC" -eq 0 ] && [ -z "$SHRUNK" ]; then
    NO_CANDIDATE="列表完整（${LIST_LINES} 行）却没有该族候选——该族可能已下架或命名已变"
    echo "WARN: [$FAMILY] ${NO_CANDIDATE}" >&2
  fi
  MODEL="$FALLBACK_MODEL"
  echo "WARN: [$FAMILY] 未解析到可用模型，回落到 $MODEL" >&2
fi
printf 'MODEL: %s (family=%s)\n' "$MODEL" "$FAMILY" >&2

# 存在性复核：钉值 / fallback 都可能指向已下架（或列表缩水时暂时消失）的 id。
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
if [ -n "$SHRUNK" ]; then
  # 钉值 / 回落值此刻在不在缩水列表里都不调用；也别让人去改钉值或 FALLBACK（列表恢复就好了）
  echo "ERROR: [$FAMILY] ${SHRUNK}；跳过调用（不要据此改 SURVEY_CURSOR_MODEL / FALLBACK_MODEL，也不要判定该族已下架）" >&2
  exit 65
fi
if [ "$LISTED" -eq 0 ]; then
  if [ -n "$NO_CANDIDATE" ]; then
    echo "ERROR: [$FAMILY] ${NO_CANDIDATE}；模型 ${MODEL} 不在实时列表，跳过调用" >&2
  else
    echo "ERROR: [$FAMILY] 模型 ${MODEL} 不在实时列表，跳过调用（钉值请改 SURVEY_CURSOR_MODEL；回落值请更新 FALLBACK_MODEL 并跑 test-model-selection.sh）" >&2
  fi
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
    echo "       该族本月不可用。三选一：换族／等额度重置／到 Cursor 后台显式开启 on-demand（另计费，用完记得关）" >&2
    exit 68
  fi
  if is_auth_error "$ERR_LOG"; then
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
