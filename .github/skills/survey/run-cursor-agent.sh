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
#                                     同版本内的系列优先顺序（靠前的强），覆盖排名文件，见 §模型选择
#   SURVEY_RANKING_FILE=<路径>        排名文件位置（缺省 <本目录>/model-ranking.conf；测试用）
#   SURVEY_TIMEOUT_SEC=<秒>           内层 watchdog，缺省 570；async 由 runner 传入
#   SURVEY_REQUIRE_SECTIONS='## A|## B'  `|` 分隔的必含段落；缺段按 exit 66
#
# Exit codes（与 run-codex.sh 同一张表）：
#   0   成功，<output-file> 已写入有效内容
#   64  参数错（含非法族）—— 主 Claude 修正调用，不是降级场景
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
  exit 66
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
#   档位  ：只收 -high / -xhigh（-extra-high 视同 xhigh）；gpt、grok 必须带档
#   gemini：主版本 ≥ 4 必须带系列名 + high/xhigh 档（gemini-4-neon-xhigh）；主版本 < 4 沿用旧规则
#           （名字含 pro、可无档位，如 gemini-3.1-pro）。版本优先，所以 Gemini 4 在列表里就必胜 3.1-pro
#   系列  ：同版本内按"优先顺序"排，靠前的强；不在顺序里的系列（含无系列）一律低于已列出的，
#           彼此按列表先后。顺序来源依次为：
#             ① 环境变量 SURVEY_SERIES_GPT / SURVEY_SERIES_GEMINI（空格分隔，单次覆盖）
#             ② 排名文件 model-ranking.conf 里该族的 series 行——上网查证后的结论，带依据 URL 与核对日期
#             ③ 排名文件缺失或读不出该族的 verified 清单 → 脚本内保底顺序 + WARN
#                （gpt "sol terra luna" / gemini "neon carbon hydrogen argon"；保底只为不中断，不代表查过）
#   新模型：**在全部筛选之前**检测——筛选只决定选不选，不决定提不提示。该族每个 id 去掉 -fast /
#           档位后缀（-preview 也去掉）得到「版本[-系列]」，不在排名文件该族的 verified 清单里、且
#           版本高于清单里的最高版本，或同为最高版本但系列没见过 → stderr 打一行
#           `NEW-MODEL: [族] <名字> 未在排名文件中核实…`（每个名字一行，写明本次选没选用）。
#           所以裸 id / 只有 -max 或低档 / -preview 首发的下一代模型也会提示（选型规则不收它们，
#           提示里写「形态不在选型规则内」）。小模型与专用形态（-mini -codex -flash…）只在版本
#           超过最高版本时提示。通过筛选的候选只要不在清单里就提示（不论版本高低）。
#           名字里有族名但形态认不出来的（xai-grok-5 / gpt6 / grok-code-5）也提示，核实后把提示里
#           的名字原样写进 verified 即可消掉。**盲区**：名字里连族名都没有的（如 OpenAI 的 o5）
#           脚本无从判断，靠 60 天复查覆盖（见 model-ranking.conf 文件头）。
#           选型不因提示改变：版本更高的新候选照样胜出（不许因为没核实就继续用旧版本）；同版本的
#           新系列不在顺序里，排在已核实系列之后。看到 NEW-MODEL 就该上网核实并更新排名文件
#           （SKILL.md 硬约束）。
#   文件自检：键名 / 段名 / 值不分大小写；不认识的键、verified 里的系列不在 series 顺序里、
#           verified 带系列却没有 series 行 → 各打一行 `WARN: [族] 排名文件 …`（doctor 汇总）
#   全族通排：-fast（插队计费）/ -none -low -medium（低档）/ -max（太慢，必超时）/
#            -codex -mini -nano -lite -flash（小或专用）/ -preview -realtime -audio -image -embed -tts
#   ⚠️ 排除项必须带前导 `-` 按分段匹配：裸 /mini/ 会把 ge-MINI 整族误杀（实测踩过）
#   比较：主版本 → 次版本 → 修订号 → 系列顺位 → 档位匹配度（偏好档 > 另一档）→ 列表先出现者
# 取列表失败 / 超时 / 无候选 → 回落到该族 FALLBACK（打 WARN）。认证失效**不回落**，exit 67。
case "$FAMILY" in                      # 各族 fallback：2026-11-19 复核均在实时列表
  gpt)    FALLBACK_MODEL="gpt-5.6-sol-high" ;;    # 2026-11-19 实测：联网搜索任务约 4 分钟
  gemini) FALLBACK_MODEL="gemini-4-neon-high" ;;
  grok)   FALLBACK_MODEL="grok-4.7-high" ;;
esac
# 列表缩水判据：Cursor 的模型列表会临时缩水到约 40 行（只剩 Grok/Kimi/GLM/DeepSeek/Composer），
# 不到一小时恢复（2026-11 多次实测）；完整列表 2026-08-30 实测 206 行、2026-11-19 实测 288 行。
# 取两者之间的 100：非空行数低于它且某族无候选 → 判"疑似临时缩水"而不是"该族已下架"。
SHRUNK_LIST_MAX_LINES=100
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
# 第二参 = effort 档**偏好**（缺省 xhigh）：版本与系列优先，同版本同系列内先挑偏好档、
# 该档没货自动落到另一档（可用性优先，不因档位缺货而整族失败）。
# 系列顺序与已核实清单在函数内读（环境变量 + 排名文件）：test-model-selection.sh 只 eval
# 这一个函数体，不能依赖函数外的变量（SKILL_DIR 例外：缺了就要求给 SURVEY_RANKING_FILE）。
pick_strongest() {
  local order="" rf="${SURVEY_RANKING_FILE:-${SKILL_DIR:-.}/model-ranking.conf}"
  case "$1" in
    gpt)    order="${SURVEY_SERIES_GPT:-}" ;;
    gemini) order="${SURVEY_SERIES_GEMINI:-}" ;;
  esac
  awk -v fam="$1" -v pref="${2:-xhigh}" -v order="$order" -v rf="$rf" '
    # 版本号按段比较（a > b 返回 1，相等 0，小于 -1）；只比前三段
    function vcmp(a, b,   x, y, i, d) {
      split(a, x, "."); split(b, y, ".")
      for (i = 1; i <= 3; i++) { d = (x[i] + 0) - (y[i] + 0); if (d != 0) return d > 0 ? 1 : -1 }
      return 0
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
      while ((getline line < rf) > 0) {
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
        line = tolower(line)
        if (line ~ /^[ \t]*\[/) { sec = line; gsub(/[^a-z]/, "", sec); continue }
        if (sec != fam) continue
        eq = index(line, "=")
        k = (eq == 0) ? line : substr(line, 1, eq - 1); v = (eq == 0) ? "" : substr(line, eq + 1)
        gsub(/[ \t]/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (eq > 0 && k == "series") fseries = v
        else if (eq > 0 && k == "verified") {
          if (v == "") continue
          ranked = 1
          nv = split(v, vv, " ")
          for (i = 1; i <= nv; i++) {
            known[vv[i]] = 1
            dash = index(vv[i], "-")
            kv = dash ? substr(vv[i], 1, dash - 1) : vv[i]
            if (kv !~ /^[0-9]+(\.[0-9]+)*$/) continue      # 认不出形态的名字（见下）没有版本可比
            if (maxver == "" || vcmp(kv, maxver) > 0) maxver = kv
            if (dash) { ks = substr(vv[i], dash + 1); if (!((kv, ks) in vser)) { vser[kv, ks] = 1; vcnt[kv]++ } }
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
        # 自检：verified 里同一版本有两个以上系列时，它们都得出现在 series 顺序里，否则顺位全是 0，
        # 会悄悄按「档位 → 列表先后」选（键名拼错 / 系列名拼错都落到这里）
        nf = split(fseries, fs, " "); for (i = 1; i <= nf; i++) inser[fs[i]] = 1
        miss = ""
        for (ck in vser) {
          split(ck, cp, SUBSEP)
          if (vcnt[cp[1]] >= 2 && !(cp[2] in inser)) miss = miss " " cp[2]
        }
        if (miss != "" && fseries == "") {
          print "WARN: [" fam "] 排名文件 " rf " 的 verified 清单带系列，却没读到 series 行（键名拼错？）——系列顺序改用脚本内保底顺序" > "/dev/stderr"
          fseries = (fam == "gpt") ? "sol terra luna" : ((fam == "gemini") ? "neon carbon hydrogen argon" : "")
        } else if (miss != "")
          print "WARN: [" fam "] 排名文件 " rf " 的 verified 清单里有系列不在 series 顺序里:" miss "（拼写？）——它们排在已列出的系列之后" > "/dev/stderr"
      }
      if (order == "") order = fseries
      # 系列顺位：靠前的分高；未列出的（含无系列）= 0
      no = split(tolower(order), ord, " ")
      for (i = 1; i <= no; i++) srank[ord[i]] = no - i + 1
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
      # ── 新模型检测：排在全部筛选之前。筛选只决定「选不选」，不许顺带决定「提不提示」──
      # 下一代模型常以选型规则不收的形态首发（裸 id / 只有 -max 或低档 / -preview / 换前缀）
      if (!pfx && index(id, fam) == 0) next               # 别族的 id
      stem = rest
      sub(/-fast$/, "", stem)
      sub(/-(xhigh|extra-high|high|max|medium|low|none)$/, "", stem)
      dstem = stem; gsub(/-preview/, "", dstem)           # 预览版与正式版算同一个名字
      dver = dstem; sub(/-.*$/, "", dver)
      if (!pfx || dver !~ /^[0-9]+(\.[0-9]+)*$/) {
        # 名字里有族名但形态认不出来（xai-grok-5 / gpt6 / grok-code-5）：无从比较版本，只能提示
        # 名字取整个 id（去档位），核实后原样写进 verified 就不再提示
        stem = id; sub(/-fast$/, "", stem); sub(/-(xhigh|extra-high|high|max|medium|low|none)$/, "", stem)
        if (ranked && !(stem in known)) note_new(stem, id, 1)
        next
      }
      if (ranked && !(dstem in known)) {
        # 小模型 / 专用形态只在版本超过已核实最高版本时提示（gpt-5.4-mini 不是新一代，gpt-7-mini 是）
        special = (id ~ /-codex/ || id ~ /-mini/ || id ~ /-nano/ || id ~ /-lite/ || id ~ /-flash/ ||
                   id ~ /-realtime/ || id ~ /-audio/ || id ~ /-image/ || id ~ /-embed/ || id ~ /-tts/)
        c = (maxver == "") ? 1 : vcmp(dver, maxver)
        if (c > 0 || (c == 0 && !special)) note_new(dstem, id, 0)
      }
      # ── 全族通排 ──
      if (id ~ /-fast$/) next
      if (id ~ /-none$/ || id ~ /-low$/ || id ~ /-medium$/ || id ~ /-max$/) next
      # ⚠️ 这些必须带前导 `-` 按**分段**匹配，不能用裸子串：
      #    裸 /mini/ 会把 ge-MINI-* 整族误杀（实测踩过）
      if (id ~ /-codex/ || id ~ /-mini/ || id ~ /-nano/ || id ~ /-lite/ || id ~ /-flash/) next
      if (id ~ /-preview/ || id ~ /-realtime/ || id ~ /-audio/ || id ~ /-image/ ||
          id ~ /-embed/ || id ~ /-tts/) next
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
        if (id !~ /pro/) next
      }
      # tier = 与偏好档的匹配度（2=偏好档 1=另一档 0=无档位）
      if (pref == "high") tier = is_h ? 2 : (is_x ? 1 : 0)
      else                tier = is_x ? 2 : (is_h ? 1 : 0)
      ser = (series in srank) ? srank[series] : 0
      # 通过全部筛选的候选：版本低于已核实最高版本的未知名字也提示（它可能被选中）
      key = ver (series != "" ? "-" series : "")
      cand[key] = 1
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
        if (newodd[i])                  how = "命名形态认不出来，本次未选用"
        else if (newkey[i] == bkey)     how = "本次已选用"
        else if (newkey[i] in cand)     how = "本次未选用"
        else                            how = "形态不在选型规则内，本次未选用"
        print "NEW-MODEL: [" fam "] " (newodd[i] ? "" : fam "-") newkey[i] " 未在排名文件中核实（实时列表里如 " newid[i] "；" \
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
fetch_model_list "$LIST_FILE"; LIST_RC=$?
case "$LIST_RC" in
  0) # 钉了模型也照跑一遍：NEW-MODEL 提示不能因为钉值而消失（钉值正是"一直用老模型"的来路）
     AUTO_MODEL=$(pick_strongest "$FAMILY" "$EFFORT" < "$LIST_FILE")
     [ -z "$MODEL" ] && MODEL="$AUTO_MODEL" ;;
  2) # 认证失效**不做**静默回落：回落只会让 --resolve-only exit 0，把 auth 故障洗成
     # "解析成功"，doctor 据此报 HEALTHY，真调用再必挂（全局约束 ⑤ fail-closed）
     echo "ERROR: [$FAMILY] cursor-agent 认证失效——跑 cursor-agent login" >&2
     head -1 "$LIST_FILE.err" >&2 2>/dev/null
     rm -f "$LIST_FILE" "$LIST_FILE.err"
     exit 67 ;;
  *) echo "WARN: 取模型列表失败或超时（>${LIST_DEADLINE}s，非认证原因）" >&2 ;;
esac

NO_CANDIDATE=""   # 列表取到了但该族一个候选都没有时的原因说明（缩水 vs 下架）
if [ -z "$MODEL" ]; then
  if [ "$LIST_RC" -eq 0 ]; then
    LIST_LINES=$(grep -cve '^[[:space:]]*$' "$LIST_FILE")
    if [ "$LIST_LINES" -lt "$SHRUNK_LIST_MAX_LINES" ]; then
      NO_CANDIDATE="模型列表疑似临时缩水（仅 ${LIST_LINES} 行，完整列表约 288 行），稍后重试"
    else
      NO_CANDIDATE="列表完整（${LIST_LINES} 行）却没有该族候选——该族可能已下架或命名已变"
    fi
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
    echo "       该族本月不可用。三选一：换族／等额度重置／到 Cursor 后台显式开启 on-demand（另计费，用完记得关）" >&2
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
