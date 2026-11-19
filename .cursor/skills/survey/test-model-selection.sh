#!/usr/bin/env bash
# /survey — 模型选择逻辑的可执行断言（配合 run-cursor-agent.sh §模型选择）
#
# 为什么要有这个文件：模型不再钉版本，靠启发式跟 Cursor 的 model id 命名走。
# Cursor 一旦改命名（新代号 / 新 effort 档 / 新形态），启发式就可能选错——这里
# 用固定 fixture 把"该选什么/不该选什么"钉成断言，改规则前先跑一遍。
#   [reviewer] = 2026-07-21 两个异构 reviewer(gpt-5.6-sol-max / -xhigh) 给出的反例
#   [regress]  = 实际踩过的 bug，改规则时别再踩回去
#
# 2026-11-19：三族（gpt / gemini / grok）都走 cursor 通道；id 按 <前缀><版本>[-<系列>][-<档位>]
# 解析，系列顺序可配。真实列表夹具在 fixtures/（full = 当天完整列表 288 行；shrunk = 临时缩水形态）。
# codex 备用通道的断言在 test-run-codex.sh。
#
# 跑：bash test-model-selection.sh   （全绿 exit 0；live 那几条需要已登录的 cursor-agent）

set -uo pipefail
# pwd -P：经符号链接调用（~/.claude/skills/survey）时 cp -R "$HERE" 会只拷到链接本身，11d 的假仓库就失效了
HERE="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPT="$HERE/run-cursor-agent.sh"
FULL_LIST="$HERE/fixtures/cursor-models-full.txt"
SHRUNK_LIST="$HERE/fixtures/cursor-models-shrunk.txt"
# 系列顺序等环境变量会改变解析结果——测试必须从缺省值出发，需要覆盖时逐条显式给
unset SURVEY_SERIES_GPT SURVEY_SERIES_GEMINI SURVEY_CURSOR_MODEL SURVEY_CURSOR_EFFORT SURVEY_RANKING_FILE
# 机制断言一律读测试自带的固定排名文件（export 给所有子进程：pick_strongest / runner / doctor）。
# 真实的 model-ranking.conf 会随查证结果合法地变（换顺序、加系列），拿它的内容当期望值，
# 「更新排名后跑测试」这一步就过不了（评审给出的复现：把 series 改成 carbon 在前 -> 9 条 FAIL）。
# 真实文件只在「真实排名文件格式校验」一节检查格式。
RANKING="$HERE/fixtures/model-ranking-test.conf"
REAL_RANKING="$HERE/model-ranking.conf"
export SURVEY_RANKING_FILE="$RANKING"
SKILL_DIR="$HERE"
# 只取 pick_strongest 函数体（awk 单函数，无外部依赖）——测试与实现不会漂移
eval "$(awk '/^pick_strongest\(\) \{/,/^\}/' "$SCRIPT")"

fail=0
# 各族 FALLBACK_MODEL 常量**从实现里读出来**，不在测试里抄第二份——抄了就会出现
# "改了实现忘了改测试"的假 FAIL。测试要守的是"回落时用的是本族 fallback"，不是"那个常量长什么样"。
fallback_of() { # <family> -> 该族 FALLBACK_MODEL 的当前值
  awk -v fam="$1" '$0 ~ "^  "fam"\\)" {
    if (match($0, /FALLBACK_MODEL="[^"]+"/)) {
      s = substr($0, RSTART, RLENGTH); gsub(/FALLBACK_MODEL="|"/, "", s); print s; exit
    }
  }' "$SCRIPT"
}
FB_GPT=$(fallback_of gpt); FB_GEMINI=$(fallback_of gemini); FB_GROK=$(fallback_of grok)
[ -n "$FB_GPT" ] && [ -n "$FB_GEMINI" ] && [ -n "$FB_GROK" ] || { echo "FAIL  读不到实现里的 FALLBACK_MODEL 常量（case 分支格式变了？）"; fail=1; }

assert() { # <family> <name> <expected> <input>
  got=$(printf '%s\n' "$4" | pick_strongest "$1" 2>/dev/null)   # stderr 的 NEW-MODEL 提示另有专门断言
  if [ "$got" = "$3" ]; then echo "PASS  [$1] $2 -> ${got:-<empty>}"
  else echo "FAIL  [$1] $2: expected '$3' got '$got'"; fail=1; fi
}

assert_env() { # <family> <name> <expected> <input> <VAR=value>（带环境变量覆盖跑一次）
  got=$(printf '%s\n' "$4" | env "$5" bash -c "SKILL_DIR='$HERE'; $(declare -f pick_strongest); pick_strongest $1" 2>/dev/null)
  if [ "$got" = "$3" ]; then echo "PASS  [$1] $2 -> ${got:-<empty>}"
  else echo "FAIL  [$1] $2: expected '$3' got '$got'"; fail=1; fi
}

echo "=== 负例：断言框架真的会失败（错误期望必须报 FAIL 并置 fail=1）==="
NEG=$( fail=0; assert gpt "故意给错的期望" "gpt-0-wrong-high" 'gpt-5.6-sol-xhigh - X'; echo "fail=$fail" )
case "$NEG" in *"FAIL  [gpt] 故意给错的期望"*"fail=1") echo "PASS  错误期望 -> assert 报 FAIL 且 fail=1";;
  *) echo "FAIL  assert 对错误期望没有报失败: $NEG"; fail=1;; esac
NEG=$( fail=0; assert gemini "故意期望非空" "gemini-4-neon-xhigh" 'gpt-5.6-sol-xhigh - X'; echo "fail=$fail" )
case "$NEG" in *"fail=1") echo "PASS  期望非空实得空 -> fail=1";; *) echo "FAIL  空结果没被判失败: $NEG"; fail=1;; esac

echo "=== live：cursor 三族各自解析 ==="
# [regress] 断言必须**版本无关**：钉死具体 id 会在 Cursor 上新版本当天变成假 FAIL。
# 真正要守的不变量只有三条：属于本族、是通用推理形态、落在高 effort 档。
LIVE=$(cursor-agent --list-models 2>/dev/null)
LIVE_LINES=$(printf '%s\n' "$LIVE" | grep -cve '^[[:space:]]*$')
live_assert() { # <family> <ERE> <人话说明>
  got=$(printf '%s\n' "$LIVE" | pick_strongest "$1")
  printf "live %-7s -> %s\n" "$1" "${got:-<empty>}"
  if [ -z "$got" ] && [ "$LIVE_LINES" -gt 0 ] && [ "$LIVE_LINES" -lt 100 ]; then
    # Cursor 列表会临时缩水（约 40 行，不到一小时恢复）——这不是规则失配，不记 FAIL，但必须说出来
    echo "SKIP live $1: 实时列表只有 ${LIVE_LINES} 行，疑似临时缩水——本条未验证，稍后重跑"
  elif [ -z "$got" ]; then
    echo "FAIL live $1: 解析为空（未登录 / 列表取不到 / 该族命名已变，规则失配）"; fail=1
  elif ! printf '%s' "$got" | grep -qE "$2"; then
    echo "FAIL live $1: '$got' 不满足「$3」（$2）"; fail=1
  fi
}
live_assert gpt    '^gpt-[0-9][0-9.]*(-[a-z0-9]+)*-(x|extra-)?high$'  'gpt 族 + high/xhigh 档'
live_assert gemini '^gemini-[0-9][0-9.]*-[a-z0-9]+-x?high$|^gemini-[0-3][0-9.]*-.*pro' 'gemini 4+ 系列+高档，或 3.x pro 线'
live_assert grok   '^(cursor-)?grok-[0-9].*-x?high$'                   'grok 族（两种前缀）+ high/xhigh 档'

echo "=== 真实列表夹具（fixtures/cursor-models-full.txt，2026-11-19 完整列表）==="
FULL=$(cat "$FULL_LIST"); SHRUNK=$(cat "$SHRUNK_LIST")
[ -n "$FULL" ] && [ -n "$SHRUNK" ] || { echo "FAIL  夹具读不到: $FULL_LIST / $SHRUNK_LIST"; fail=1; }
assert gpt    "完整列表 -> 5.6 + sol 系列 + xhigh"            "gpt-5.6-sol-xhigh"   "$FULL"
assert gemini "完整列表 -> Gemini 4 Neon xhigh（胜 3.1-pro 与其它系列）" "gemini-4-neon-xhigh" "$FULL"
assert grok   "完整列表 -> grok-4.7（无 cursor- 前缀）胜 cursor-grok-4.6" "grok-4.7-xhigh" "$FULL"
for f in gpt gemini grok; do
  got=$(printf '%s\n' "$FULL" | pick_strongest "$f" high)
  case "$f" in gpt) want=gpt-5.6-sol-high;; gemini) want=gemini-4-neon-high;; grok) want=grok-4.7-high;; esac
  [ "$got" = "$want" ] && echo "PASS  [$f] 完整列表偏好 high -> $got" || { echo "FAIL  [$f] 偏好 high: 期望 $want 实得 '$got'"; fail=1; }
done
# 各族 fallback 必须真实存在于完整列表（否则回落即 fail-closed，等于没有 fallback）
for m in "$FB_GPT" "$FB_GEMINI" "$FB_GROK"; do
  awk -v id="$m" '$1 == id {f=1} END {exit !f}' "$FULL_LIST" && echo "PASS  fallback $m 在完整列表里" || { echo "FAIL  fallback $m 不在完整列表"; fail=1; }
done
assert gpt    "缩水列表（只剩 grok/kimi/glm/deepseek/composer）-> 空" "" "$SHRUNK"
assert gemini "缩水列表 -> 空"                                         "" "$SHRUNK"
assert grok   "缩水列表里 grok 仍可解析"                               "grok-4.7-xhigh" "$SHRUNK"

echo "=== 系列顺序（SURVEY_SERIES_GPT / SURVEY_SERIES_GEMINI）==="
assert gpt "5.6 胜 5.5（版本优先于系列与档位）" "gpt-5.6-luna-high" 'gpt-5.5-extra-high - X
gpt-5.6-luna-high - X'
assert gpt "缺省顺序 sol > terra > luna（与列表先后无关）" "gpt-5.6-sol-xhigh" 'gpt-5.6-luna-xhigh - X
gpt-5.6-terra-xhigh - X
gpt-5.6-sol-xhigh - X'
assert gpt "terra > luna" "gpt-5.6-terra-xhigh" 'gpt-5.6-luna-xhigh - X
gpt-5.6-terra-xhigh - X'
assert gpt "系列优先于档位：sol-high 胜 luna-xhigh" "gpt-5.6-sol-high" 'gpt-5.6-luna-xhigh - X
gpt-5.6-sol-high - X'
assert gpt "未列出的系列低于已列出的" "gpt-5.6-luna-xhigh" 'gpt-5.6-nova-xhigh - X
gpt-5.6-luna-xhigh - X'
assert gpt "未列出的系列之间按列表先后" "gpt-5.6-nova-xhigh" 'gpt-5.6-nova-xhigh - X
gpt-5.6-vega-xhigh - X'
assert_env gpt "环境变量覆盖：luna 排第一" "gpt-5.6-luna-xhigh" "$FULL" 'SURVEY_SERIES_GPT=luna sol terra'
assert_env gemini "环境变量覆盖：hydrogen 排第一" "gemini-4-hydrogen-xhigh" "$FULL" 'SURVEY_SERIES_GEMINI=hydrogen neon'
assert_env gemini "环境变量覆盖：只列 carbon（该系列无 xhigh -> 落 high）" "gemini-4-carbon-high" "$FULL" 'SURVEY_SERIES_GEMINI=carbon'
assert gemini "Neon 胜其它系列（即使它们先出现）" "gemini-4-neon-high" 'gemini-4-hydrogen-xhigh - X
gemini-4-carbon-high - X
gemini-4-neon-high - X'
assert gemini "Neon 缺货时按排名顺序落到 Carbon" "gemini-4-carbon-high" 'gemini-4-carbon-high - X
gemini-4-hydrogen-high - X
gemini-3.1-pro - X'
# 2026-11-19：排名文件把 carbon / hydrogen 都列进了顺序，这条要守的"未列出的系列之间"机制改用显式顺序触发
assert_env gemini "Neon 缺货时未列出的系列之间先比档位再比先后" "gemini-4-hydrogen-xhigh" 'gemini-4-carbon-high - X
gemini-4-hydrogen-xhigh - X' 'SURVEY_SERIES_GEMINI=neon'
assert gemini "Gemini 4 任一系列都胜 3.1-pro" "gemini-4-argon-high" 'gemini-3.1-pro - X
gemini-4-argon-high - X'
assert gemini "Gemini 4 只有 low/medium 档时退回 3.1-pro" "gemini-3.1-pro" 'gemini-4-neon-low - X
gemini-4-neon-medium - X
gemini-3.1-pro - X'
assert gemini "Gemini 4 的 flash 不入选" "gemini-3.1-pro" 'gemini-4-flash-high - X
gemini-3.1-pro - X'

echo "=== 排名文件驱动系列顺序 + 新模型提示（机制断言，用 fixtures/model-ranking-test.conf）==="
RK="$(mktemp -d)"
# pick2 <family> <effort> <input> [VAR=value ...]：stdout 落 $RK/out，stderr 落 $RK/err
pick2() {
  local f="$1" e="$2" in="$3"; shift 3
  printf '%s\n' "$in" | env "$@" bash -c "SKILL_DIR='$HERE'; $(declare -f pick_strongest); pick_strongest $f $e" >"$RK/out" 2>"$RK/err"
}
expect_pick() { # <name> <expected-id>
  local got; got=$(cat "$RK/out")
  [ "$got" = "$2" ] && echo "PASS  $1 -> ${got:-<empty>}" || { echo "FAIL  $1: 期望 '$2' 实得 '$got'"; fail=1; }
}
expect_err() { # <name> <substr>：stderr 必须含
  case "$(cat "$RK/err")" in *"$2"*) echo "PASS  $1";; *) echo "FAIL  $1: stderr 应含 '$2'，实得: $(cat "$RK/err")"; fail=1;; esac
}
expect_no_err() { # <name> <substr>：stderr 不得含
  case "$(cat "$RK/err")" in *"$2"*) echo "FAIL  $1: stderr 不应含 '$2'，实得: $(cat "$RK/err")"; fail=1;; *) echo "PASS  $1";; esac
}
[ -s "$RANKING" ] && echo "PASS  测试用排名文件存在: fixtures/model-ranking-test.conf" || { echo "FAIL  测试用排名文件缺失: $RANKING"; fail=1; }

# ① 顺序来自文件：换一份顺序相反的假文件，结果必须跟着变（证明不是脚本里的缺省值在起作用）
cat > "$RK/reversed.conf" <<'EOF'
# 假排名：顺序与真文件相反
[gpt]
checked = 2026-11-19
series = luna terra sol
verified = 5.6-sol 5.6-terra 5.6-luna 5.5 5.4 5.2 5.1
[gemini]
checked = 2026-11-19
series = argon hydrogen carbon neon
verified = 4-neon 4-carbon 4-hydrogen 4-argon 3.1-pro
[grok]
checked = 2026-11-19
verified = 4.7 4.6 4.5
EOF
pick2 gpt xhigh "$FULL" "SURVEY_RANKING_FILE=$RK/reversed.conf";    expect_pick "[gpt] 假文件把 luna 排第一 -> 选 luna" "gpt-5.6-luna-xhigh"
pick2 gemini xhigh "$FULL" "SURVEY_RANKING_FILE=$RK/reversed.conf"; expect_pick "[gemini] 假文件把 argon 排第一 -> 选 argon（只有 high 档）" "gemini-4-argon-high"
pick2 gemini xhigh 'gemini-4-hydrogen-xhigh - X
gemini-4-carbon-high - X' "SURVEY_RANKING_FILE=$RANKING";           expect_pick "[gemini] 排名文件里 carbon 在 hydrogen 之前（系列先于档位）" "gemini-4-carbon-high"
pick2 gemini xhigh 'gemini-4-argon-high - X
gemini-4-hydrogen-high - X' "SURVEY_RANKING_FILE=$RANKING";         expect_pick "[gemini] 排名文件里 hydrogen 在 argon 之前" "gemini-4-hydrogen-high"

# ② 环境变量覆盖优先于文件
pick2 gpt xhigh "$FULL" "SURVEY_RANKING_FILE=$RK/reversed.conf" "SURVEY_SERIES_GPT=terra"
expect_pick "[gpt] SURVEY_SERIES_GPT 优先于排名文件" "gpt-5.6-terra-xhigh"
pick2 gemini xhigh "$FULL" "SURVEY_RANKING_FILE=$RK/reversed.conf" "SURVEY_SERIES_GEMINI=carbon neon"
expect_pick "[gemini] SURVEY_SERIES_GEMINI 优先于排名文件" "gemini-4-carbon-high"

# ③ 文件缺失 / 没有该族 -> 保底顺序 + WARN，不打 NEW-MODEL（没有清单就无从判断）
for f in gpt gemini grok; do
  case "$f" in gpt) want=gpt-5.6-sol-xhigh;; gemini) want=gemini-4-neon-xhigh;; grok) want=grok-4.7-xhigh;; esac
  pick2 "$f" xhigh "$FULL" "SURVEY_RANKING_FILE=$RK/does-not-exist.conf"
  expect_pick "[$f] 排名文件缺失 -> 保底顺序仍选出" "$want"
  expect_err  "[$f] 排名文件缺失 -> 打 WARN" "WARN: [$f] 排名文件"
  expect_err  "[$f] WARN 说明用的是保底顺序" "保底顺序"
  expect_no_err "[$f] 排名文件缺失时不打 NEW-MODEL" "NEW-MODEL"
done
printf '[gpt]\nchecked = 2026-11-19\nseries = sol terra luna\nverified = 5.6-sol\n' > "$RK/gpt-only.conf"
pick2 gemini xhigh "$FULL" "SURVEY_RANKING_FILE=$RK/gpt-only.conf"
expect_pick "[gemini] 文件里没有本族 -> 保底顺序" "gemini-4-neon-xhigh"
expect_err  "[gemini] 文件里没有本族 -> 打 WARN" "WARN: [gemini] 排名文件"
pick2 gemini xhigh 'gemini-4-hydrogen-xhigh - X
gemini-4-carbon-high - X' "SURVEY_RANKING_FILE=$RK/does-not-exist.conf"
expect_pick "[gemini] 保底顺序里 carbon 仍在 hydrogen 之前" "gemini-4-carbon-high"

# ④ 版本更高的新模型：必须被选中，且有 NEW-MODEL 提示
pick2 gpt xhigh "$FULL
gpt-6.2-astra-high - New" "SURVEY_RANKING_FILE=$RANKING"
expect_pick "[gpt] 更高版本的新模型被选中（不因没核实而继续用旧版本）" "gpt-6.2-astra-high"
expect_err  "[gpt] 更高版本 -> NEW-MODEL 固定前缀 + 名字" "NEW-MODEL: [gpt] gpt-6.2-astra 未在排名文件中核实"
expect_err  "[gpt] 提示里写明本次已选用" "本次已选用"
pick2 gemini high "$FULL
gemini-5-helium-high - New" "SURVEY_RANKING_FILE=$RANKING"
expect_pick "[gemini] 更高版本的新模型被选中" "gemini-5-helium-high"
expect_err  "[gemini] 更高版本 -> NEW-MODEL" "NEW-MODEL: [gemini] gemini-5-helium 未在排名文件中核实"
pick2 grok xhigh "$FULL
grok-5-xhigh - New" "SURVEY_RANKING_FILE=$RANKING"
expect_pick "[grok] 更高版本的新模型被选中" "grok-5-xhigh"
expect_err  "[grok] 更高版本 -> NEW-MODEL" "NEW-MODEL: [grok] grok-5 未在排名文件中核实"

# ⑤ 同版本的新系列：核实前不被选中，但必须有提示
pick2 gemini xhigh "gemini-4-xenon-xhigh - New
$FULL" "SURVEY_RANKING_FILE=$RANKING"
expect_pick "[gemini] 同版本新系列不被选中（即使先出现）" "gemini-4-neon-xhigh"
expect_err  "[gemini] 同版本新系列 -> NEW-MODEL" "NEW-MODEL: [gemini] gemini-4-xenon 未在排名文件中核实"
expect_err  "[gemini] 提示里写明本次未选用" "本次未选用"
pick2 gpt xhigh "gpt-5.6-nova-xhigh - New
$FULL" "SURVEY_RANKING_FILE=$RANKING"
expect_pick "[gpt] 同版本新系列不被选中" "gpt-5.6-sol-xhigh"
expect_err  "[gpt] 同版本新系列 -> NEW-MODEL" "NEW-MODEL: [gpt] gpt-5.6-nova 未在排名文件中核实"
pick2 gemini xhigh "gemini-4-xenon-xhigh - New
gemini-4-xenon-high - New
$FULL" "SURVEY_RANKING_FILE=$RANKING"
N=$(grep -c '^NEW-MODEL:' "$RK/err")
[ "$N" = "1" ] && echo "PASS  同一个新名字的多个档位只提示一行" || { echo "FAIL  期望 1 行 NEW-MODEL 实得 $N"; fail=1; }
pick2 gpt xhigh "$FULL" "SURVEY_RANKING_FILE=$RANKING" "SURVEY_SERIES_GPT=nova sol"
expect_no_err "[gpt] 顺序被环境变量覆盖时，已核实的模型仍不提示" "NEW-MODEL"
pick2 gpt xhigh "gpt-5.6-nova-xhigh - New
$FULL" "SURVEY_RANKING_FILE=$RANKING" "SURVEY_SERIES_GPT=nova sol"
expect_pick "[gpt] 环境变量把未核实系列排第一 -> 照环境变量选" "gpt-5.6-nova-xhigh"
expect_err  "[gpt] ……但提示不因覆盖而消失" "NEW-MODEL: [gpt] gpt-5.6-nova"

# ⑥ 列表里全是已核实模型 -> 没有任何提示（测试用排名文件 × 完整列表夹具，两种档位）
for f in gpt gemini grok; do
  for e in high xhigh; do
    pick2 "$f" "$e" "$FULL" "SURVEY_RANKING_FILE=$RANKING"
    [ -s "$RK/err" ] && { echo "FAIL  [$f/$e] 完整列表不应有任何 stderr: $(cat "$RK/err")"; fail=1; } || echo "PASS  [$f/$e] 完整列表全是已核实模型 -> 无提示"
  done
done
# ⑦ [reviewer 2026-11-19] 新模型检测排在筛选之前：选型规则不收的形态也必须提示。
#    原实现只看通过筛选的候选，下面这些全部静默（doctor 还报「没有未核实的新模型」）。
nm_case() { # <family> <id 行> <期望选中> <期望 stderr 子串> <说明>
  pick2 "$1" xhigh "$FULL
$2 - New" "SURVEY_RANKING_FILE=$RANKING"
  expect_pick "[$1] $5：选型不变" "$3"
  expect_err  "[$1] $5：有 NEW-MODEL" "$4"
}
nm_case gemini gemini-5-high              gemini-4-neon-xhigh "NEW-MODEL: [gemini] gemini-5 未在排名文件中核实"       "gemini 5 不带系列名"
nm_case gemini gemini-5-pro               gemini-4-neon-xhigh "NEW-MODEL: [gemini] gemini-5-pro 未在排名文件中核实"   "gemini-5-pro 无档位"
nm_case gemini gemini-5-neon              gemini-4-neon-xhigh "NEW-MODEL: [gemini] gemini-5-neon 未在排名文件中核实"  "裸 gemini-5-neon"
nm_case gemini gemini-5-neon-preview-high gemini-4-neon-xhigh "NEW-MODEL: [gemini] gemini-5-neon 未在排名文件中核实"  "preview 首发"
nm_case gpt    gpt-6                      gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt-6 未在排名文件中核实"             "裸 gpt-6"
nm_case gpt    gpt-6-max                  gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt-6 未在排名文件中核实"             "只有 -max"
nm_case gpt    gpt-6.2-astra-medium       gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt-6.2-astra 未在排名文件中核实"     "只有低档"
nm_case gpt    gpt-6.2-astra-max-fast     gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt-6.2-astra 未在排名文件中核实"     "-max-fast"
nm_case gpt    gpt-6-preview-high         gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt-6 未在排名文件中核实"             "gpt preview"
nm_case gpt    gpt-7-mini-high            gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt-7-mini 未在排名文件中核实"        "更高版本的小模型（说明新一代已到）"
nm_case gpt    gpt-5.6-nova-max           gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt-5.6-nova 未在排名文件中核实"      "同为最高版本的新系列只有 -max"
nm_case grok   grok-5                     grok-4.7-xhigh      "NEW-MODEL: [grok] grok-5 未在排名文件中核实"           "裸 grok-5"
nm_case grok   grok-5-max                 grok-4.7-xhigh      "NEW-MODEL: [grok] grok-5 未在排名文件中核实"           "grok 只有 -max"
nm_case grok   cursor-grok-5-low          grok-4.7-xhigh      "NEW-MODEL: [grok] grok-5 未在排名文件中核实"           "cursor- 前缀的低档"
# 命名形态认不出来（换前缀 / 版本段不是数字）：无从比较版本，照样提示，名字取整个 id
nm_case grok   xai-grok-5-high            grok-4.7-xhigh      "NEW-MODEL: [grok] xai-grok-5 未在排名文件中核实"       "换了前缀"
nm_case grok   grok-code-5-high           grok-4.7-xhigh      "NEW-MODEL: [grok] grok-code-5 未在排名文件中核实"      "版本段不是数字"
nm_case gpt    gpt6-high                  gpt-5.6-sol-xhigh   "NEW-MODEL: [gpt] gpt6 未在排名文件中核实"              "前缀少了连字符"
pick2 gpt xhigh "$FULL
gpt-6-max - New" "SURVEY_RANKING_FILE=$RANKING"
expect_err "[gpt] 没被选型规则收的新模型，提示里写明原因" "形态不在选型规则内，本次未选用"
pick2 grok xhigh "$FULL
xai-grok-5-high - New" "SURVEY_RANKING_FILE=$RANKING"
expect_err "[grok] 认不出形态的，提示里写明原因" "命名形态认不出来，本次未选用"
pick2 gpt xhigh "$FULL
gpt-6 - a
gpt-6-max - b
gpt-6-preview-high - c
gpt-6-low-fast - d" "SURVEY_RANKING_FILE=$RANKING"
N=$(grep -c '^NEW-MODEL:' "$RK/err")
[ "$N" = "1" ] && echo "PASS  同一个新名字的多种形态只提示一行" || { echo "FAIL  期望 1 行 NEW-MODEL 实得 $N: $(cat "$RK/err")"; fail=1; }
# 不该提示的：已核实模型的任何形态；不高于最高版本的小模型 / 专用形态；别族的 id
pick2 gpt xhigh "$FULL
gpt-5.6-sol-preview-high - X
gpt-5.6-mini-high - X
gpt-5.5-nano - X
gpt-5.6-codex-xhigh - X
o5-high - X
claude-opus-9-max - X" "SURVEY_RANKING_FILE=$RANKING"
expect_pick "[gpt] 不该提示的形态不影响选型" "gpt-5.6-sol-xhigh"
[ -s "$RK/err" ] && { echo "FAIL  [gpt] 已核实模型的其它形态 / 同代小模型 / 别族 id 不应有提示: $(cat "$RK/err")"; fail=1; } || echo "PASS  [gpt] 已核实模型的其它形态 / 同代小模型 / 别族 id -> 无提示"
# 认不出形态的名字，核实后原样写进 verified 就不再提示
sed 's/^verified = 4.7 4.6 4.5/verified = 4.7 4.6 4.5 xai-grok-5 grok-code-5/' "$RANKING" > "$RK/ack.conf"
pick2 grok xhigh "$FULL
xai-grok-5-high - X
grok-code-5-high - X" "SURVEY_RANKING_FILE=$RK/ack.conf"
[ -s "$RK/err" ] && { echo "FAIL  [grok] 写进 verified 的名字仍在提示: $(cat "$RK/err")"; fail=1; } || echo "PASS  [grok] 认不出形态的名字写进 verified 后不再提示"
# 已知盲区（钉住现状，文档里写明靠 60 天复查覆盖）：名字里不含族名的新模型检测不到
pick2 gpt xhigh "$FULL
o5-high - X" "SURVEY_RANKING_FILE=$RANKING"
expect_no_err "[gpt] 盲区：名字里不含族名的 o5 检测不到（文档已写明）" "NEW-MODEL"
grep -q '盲区' "$REAL_RANKING" && grep -q '盲区' "$HERE/SKILL.md" && echo "PASS  盲区写进了排名文件头与 SKILL.md" || { echo "FAIL  盲区没有写进 model-ranking.conf / SKILL.md"; fail=1; }

# ⑧ [reviewer 2026-11-19] 排名文件写错大小写 / 拼错键名 / 拼错系列名：不许静默用错顺序
NOTOP=$(printf '%s\n' "$FULL" | grep -v '^gemini-4-neon\|^gpt-5.6-sol')   # Neon / Sol 缺货时顺序才看得出来
sed 's/^series   = sol terra luna/series   = Sol Terra Luna/; s/^series   = neon carbon hydrogen argon/Series = Neon Carbon Hydrogen Argon/; s/^\[gpt\]/[GPT]/; s/^verified = 4-neon/VERIFIED = 4-Neon/' "$RANKING" > "$RK/case.conf"
pick2 gemini xhigh "$NOTOP" "SURVEY_RANKING_FILE=$RK/case.conf"
expect_pick "[gemini] 键名与系列名写成大写 -> 顺序照样生效" "gemini-4-carbon-high"
[ -s "$RK/err" ] && { echo "FAIL  [gemini] 大小写不同不应有提示: $(cat "$RK/err")"; fail=1; } || echo "PASS  [gemini] 大小写不同 -> 无提示"
pick2 gpt high "$NOTOP" "SURVEY_RANKING_FILE=$RK/case.conf"
expect_pick "[gpt] 段名 [GPT] + 系列名大写 -> 顺序照样生效" "gpt-5.6-terra-high"
[ -s "$RK/err" ] && { echo "FAIL  [gpt] 大小写不同不应有提示: $(cat "$RK/err")"; fail=1; } || echo "PASS  [gpt] 大小写不同 -> 无提示"
sed 's/^series   = neon/serise   = neon/' "$RANKING" > "$RK/typo-key.conf"
pick2 gemini xhigh "$NOTOP" "SURVEY_RANKING_FILE=$RK/typo-key.conf"
expect_err  "[gemini] 键名拼错 -> WARN 点名这个键" "排名文件 $RK/typo-key.conf 里有不认识的行「serise」"
expect_err  "[gemini] 键名拼错 -> WARN 说明没读到 series 行" "却没读到 series 行"
expect_pick "[gemini] 键名拼错 -> 改用保底顺序，不按档位乱选" "gemini-4-carbon-high"
sed 's/^series   = neon carbon/series   = neon carbno/' "$RANKING" > "$RK/typo-ser.conf"
pick2 gemini xhigh "$NOTOP" "SURVEY_RANKING_FILE=$RK/typo-ser.conf"
expect_err  "[gemini] 系列名拼错 -> WARN 点名 verified 里不在顺序中的系列" "有系列不在 series 顺序里: carbon"
sed 's/$/\r/' "$RANKING" > "$RK/crlf.conf"
pick2 gemini xhigh "$NOTOP" "SURVEY_RANKING_FILE=$RK/crlf.conf"
expect_pick "[gemini] CRLF 换行的排名文件照常读" "gemini-4-carbon-high"
[ -s "$RK/err" ] && { echo "FAIL  [gemini] CRLF 不应有提示: $(cat "$RK/err")"; fail=1; } || echo "PASS  [gemini] CRLF -> 无提示"
# 单版本只有一个系列（gemini 3.1-pro）不需要顺序，不许误报
pick2 gemini xhigh "$FULL" "SURVEY_RANKING_FILE=$RANKING"
expect_no_err "[gemini] 3.1-pro 这种单系列版本不触发自检 WARN" "WARN"

echo "=== 真实排名文件格式校验（model-ranking.conf：只验格式，不验顺序）==="
# 顺序是查证结论，会合法地变；这里守的只有：三族都有 checked（日期格式）与 verified、
# 文件对完整列表夹具不产生任何 WARN / NEW-MODEL（清单覆盖全部候选、没有拼错的键和系列）、
# 解析结果确实是夹具里的 id。
validate_ranking() { # <文件> -> 通过返回 0；问题打到 stdout
  local file="$1" bad=0 f e got
  for f in gpt gemini grok; do
    awk -v fam="$f" '
      { sub(/\r$/, ""); $0 = tolower($0) }
      /^[ \t]*\[/ { sec = $0; gsub(/[^a-z]/, "", sec); next }
      sec != fam { next }
      /^[ \t]*checked[ \t]*=[ \t]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]*$/ { c = 1 }
      /^[ \t]*verified[ \t]*=[ \t]*[^ \t]/ { v = 1 }
      END { exit !(c && v) }' "$file" || { echo "[$f] 缺 checked（YYYY-MM-DD）或 verified"; bad=1; }
    for e in high xhigh; do
      pick2 "$f" "$e" "$FULL" "SURVEY_RANKING_FILE=$file"
      got=$(cat "$RK/out")
      [ -s "$RK/err" ] && { echo "[$f/$e] 对完整列表夹具有提示: $(cat "$RK/err")"; bad=1; }
      awk -v id="$got" '$1 == id {f=1} END {exit !f}' "$FULL_LIST" || { echo "[$f/$e] 解析结果 '$got' 不在完整列表夹具里"; bad=1; }
    done
  done
  return $bad
}
MSG=$(validate_ranking "$REAL_RANKING") && echo "PASS  真实排名文件格式校验通过" || { echo "FAIL  真实排名文件格式校验: $MSG"; fail=1; }
# [reviewer] 合法地改顺序（文件注释自己建议的做法）不许让测试变红
sed 's/^series\([ ]*\)=\([ ]*\)neon carbon/series\1=\2carbon neon/' "$REAL_RANKING" > "$RK/real-carbon-first.conf"
if cmp -s "$REAL_RANKING" "$RK/real-carbon-first.conf"; then
  sed 's/^series\([ ]*\)=\([ ]*\)carbon neon/series\1=\2neon carbon/' "$REAL_RANKING" > "$RK/real-carbon-first.conf"   # 真实文件已经是 carbon 在前就反过来换
fi
cmp -s "$REAL_RANKING" "$RK/real-carbon-first.conf" && echo "SKIP  真实文件里找不到 neon / carbon 相邻的 series 行，换序校验未执行" || {
  MSG=$(validate_ranking "$RK/real-carbon-first.conf") && echo "PASS  真实排名文件换了系列顺序 -> 格式校验照样通过" || { echo "FAIL  换序后格式校验不过: $MSG"; fail=1; }
}
# 负例：校验真的会失败
sed 's/^verified = 4-neon/verified = 4-neno/' "$RANKING" > "$RK/bad1.conf"
validate_ranking "$RK/bad1.conf" >/dev/null && { echo "FAIL  verified 清单漏了候选却通过了校验"; fail=1; } || echo "PASS  负例：verified 漏掉夹具里的候选 -> 校验失败"
grep -v '^checked' "$RANKING" > "$RK/bad2.conf"
validate_ranking "$RK/bad2.conf" >/dev/null && { echo "FAIL  缺 checked 却通过了校验"; fail=1; } || echo "PASS  负例：缺 checked -> 校验失败"
sed 's/^series   = neon/serise   = neon/' "$RANKING" > "$RK/bad3.conf"
validate_ranking "$RK/bad3.conf" >/dev/null && { echo "FAIL  键名拼错却通过了校验"; fail=1; } || echo "PASS  负例：键名拼错 -> 校验失败"
# 机制断言不读真实文件：测试进程里 SURVEY_RANKING_FILE 必须指向夹具
[ "$SURVEY_RANKING_FILE" = "$HERE/fixtures/model-ranking-test.conf" ] && echo "PASS  机制断言读的是 fixtures/model-ranking-test.conf，不是真实排名文件" || { echo "FAIL  SURVEY_RANKING_FILE 被改成了 $SURVEY_RANKING_FILE"; fail=1; }
rm -rf "$RK"

echo "=== 全族通排（用 gpt fixture 测族无关规则）==="
assert gpt "排除 -fast" "gpt-5.6-sol-xhigh" 'gpt-5.6-sol-xhigh-fast - X
gpt-5.6-sol-xhigh - X'
assert gpt "排除 -codex" "gpt-5.5-high" 'gpt-5.9-codex-xhigh - X
gpt-5.5-high - X'
assert gpt "排除 -mini/-nano" "gpt-5.4-high" 'gpt-5.8-mini-xhigh - X
gpt-5.7-nano-high - X
gpt-5.4-high - X'
assert gpt "排除 none/low/medium" "gpt-5.2-high" 'gpt-5.9-sol-medium - X
gpt-5.9-sol-low - X
gpt-5.9-sol-none - X
gpt-5.2-high - X'
assert gpt "auto 不入选" "gpt-5.6-sol-xhigh" 'auto - Auto (default)
gpt-5.6-sol-xhigh - X'
assert gpt "[reviewer] -lite 排除（版本更高也不要）" "gpt-5.6-sol-xhigh" 'gpt-6-lite-xhigh - X
gpt-5.6-sol-xhigh - X'
assert gpt "max 不入选，退而选 xhigh" "gpt-5.6-sol-xhigh" 'gpt-5.6-sol-max - X
gpt-5.6-sol-xhigh - X'
assert gpt "只有 max 时选不出来（触发 fallback）" "" 'gpt-5.6-sol-max - X
gpt-5.6-sol-max-fast - X'
assert gpt "gpt-6-preview 不得击败 gpt-5.6-terra-xhigh" "gpt-5.6-terra-xhigh" 'gpt-6-preview - X
gpt-5.6-terra-xhigh - X'
assert gpt "gpt-6-realtime / -audio 拒绝" "gpt-5.6-sol-xhigh" 'gpt-6-realtime - X
gpt-6-audio-xhigh - X
gpt-5.6-sol-xhigh - X'
assert gpt "裸 gpt-7（默认只是 medium 档）不得入选" "gpt-5.6-sol-xhigh" 'gpt-7 - X
gpt-5.6-sol-xhigh - X'
assert gpt "裸 gpt-5.7 不得击败 5.6 的 xhigh" "gpt-5.6-sol-xhigh" 'gpt-5.7 - X
gpt-5.6-sol-xhigh - X'

echo "=== 版本比较 ==="
assert gpt "版本大优先于档位" "gpt-5.9-a-high" 'gpt-5.6-sol-xhigh - X
gpt-5.9-a-high - X'
assert gpt "同版本 xhigh > high" "gpt-5.6-a-xhigh" 'gpt-5.6-a-high - X
gpt-5.6-a-xhigh - X'
assert gpt "extra-high 视为 xhigh" "gpt-5.5-extra-high" 'gpt-5.5-high - X
gpt-5.5-extra-high - X'
assert gpt "minor 按数值比 5.10 > 5.6" "gpt-5.10-a-xhigh" 'gpt-5.6-sol-xhigh - X
gpt-5.10-a-xhigh - X'
assert gpt "major 比较 6.0 > 5.10" "gpt-6.0-a-xhigh" 'gpt-5.10-a-xhigh - X
gpt-6.0-a-xhigh - X'
assert gpt "[reviewer] 三段版本号 6.0.1 不再被丢弃" "gpt-6.0.1-a-xhigh" 'gpt-6.0-a-xhigh - X
gpt-6.0.1-a-xhigh - X'
assert gpt "[reviewer] 第三段按数值比 6.0.10 > 6.0.2" "gpt-6.0.10-a-xhigh" 'gpt-6.0.2-a-xhigh - X
gpt-6.0.10-a-xhigh - X'
assert gpt "同版同档取列表先出现者" "gpt-5.6-sol-xhigh" 'gpt-5.6-sol-xhigh - X
gpt-5.6-luna-xhigh - X'

echo "=== effort 档偏好（pick_strongest 第二参 / SURVEY_CURSOR_EFFORT）==="
BOTH='gpt-5.6-sol-xhigh - X
gpt-5.6-sol-high - X
gpt-5.5-extra-high - X'
got=$(printf '%s\n' "$BOTH" | pick_strongest gpt high)
[ "$got" = "gpt-5.6-sol-high" ] && echo "PASS  effort=high 同版本先挑 high" || { echo "FAIL  effort=high: 期望 gpt-5.6-sol-high 实得 '$got'"; fail=1; }
got=$(printf '%s\n' 'gpt-5.6-sol-xhigh - X' | pick_strongest gpt high)
[ "$got" = "gpt-5.6-sol-xhigh" ] && echo "PASS  high 档缺货自动落 xhigh（可用性优先）" || { echo "FAIL  落档: 实得 '$got'"; fail=1; }
got=$(printf '%s\n' 'gpt-5.6-extra-high - X
gpt-5.6-luna-high - X' | pick_strongest gpt high 2>/dev/null)
[ "$got" = "gpt-5.6-luna-high" ] && echo "PASS  extra-high 不被 /-high\$/ 误当 high 档" || { echo "FAIL  extra-high 混档: 实得 '$got'"; fail=1; }
got=$(printf '%s\n' "$BOTH" | pick_strongest gpt)
[ "$got" = "gpt-5.6-sol-xhigh" ] && echo "PASS  缺省仍 xhigh 优先（旧行为不变）" || { echo "FAIL  缺省档变了: 实得 '$got'"; fail=1; }
got=$(printf '%s\n' 'gpt-5.9-a-high - X
gpt-5.6-sol-xhigh - X' | pick_strongest gpt high 2>/dev/null)
[ "$got" = "gpt-5.9-a-high" ] && echo "PASS  版本仍优先于档位（high 偏好下）" || { echo "FAIL  版本优先破坏: 实得 '$got'"; fail=1; }

echo "=== gemini 族 ==="
assert gemini "[regress] 不被 -mini 规则误杀（ge-MINI 含 mini）" "gemini-3.1-pro" 'gemini-3.1-pro - X'
assert gemini "flash 版本更高也不得击败 pro（flash 是小模型）" "gemini-3.1-pro" 'gemini-3.5-flash - X
gemini-3.1-pro - X'
assert gemini "无 pro 的裸 id 不入选" "" 'gemini-4 - X'
assert gemini "3.x pro 版本大者胜" "gemini-3.5-pro" 'gemini-3.1-pro - X
gemini-3.5-pro - X'
assert gemini "主版本 ≥4 无档位的裸 pro 不入选（4+ 必须系列+档位）" "gemini-3.1-pro" 'gemini-3.1-pro - X
gemini-4.0-pro - X'
assert gemini "未来带 effort 后缀时 high > 无后缀" "gemini-4-pro-high" 'gemini-4-pro - X
gemini-4-pro-high - X'
assert gemini "pro 的 low/medium 档不入选" "gemini-3.1-pro" 'gemini-9-pro-low - X
gemini-9-pro-medium - X
gemini-3.1-pro - X'

echo "=== grok 族 ==="
assert grok "认 cursor- 前缀，取 high" "cursor-grok-4.5-high" 'cursor-grok-4.5-high - X
cursor-grok-4.5-medium - X
cursor-grok-4.5-low - X'
assert grok "排除 -fast" "cursor-grok-4.5-high" 'cursor-grok-4.5-high-fast - X
cursor-grok-4.5-high - X'
assert grok "版本大者胜" "cursor-grok-5-high" 'cursor-grok-4.5-high - X
cursor-grok-5-high - X'

assert grok "无 cursor- 前缀的 grok-4.7 胜 cursor-grok-4.6" "grok-4.7-high" 'cursor-grok-4.6-xhigh - X
grok-4.7-high - X'
assert grok "同版本两种前缀并存时按档位" "cursor-grok-4.7-xhigh" 'grok-4.7-high - X
cursor-grok-4.7-xhigh - X'
assert grok "grok 的 -max / -fast / low 档不入选" "" 'grok-4.7-max - X
grok-4.7-xhigh-fast - X
grok-4.7-low - X'

echo "=== 跨族隔离（一族的规则不许选到别族）==="
CROSS='gpt-5.6-sol-xhigh - X
gemini-3.1-pro - X
cursor-grok-4.5-high - X'
assert gpt    "gpt 只选 gpt"       "gpt-5.6-sol-xhigh"    "$CROSS"
assert gemini "gemini 只选 gemini" "gemini-3.1-pro"       "$CROSS"
assert grok   "grok 只选 grok"     "cursor-grok-4.5-high" "$CROSS"
assert gemini "该族无候选 -> 空（触发 fallback）" "" 'gpt-5.6-sol-xhigh - X'

echo "=== 空/异常输入 ==="
assert gpt "空列表 -> 空" "" 'Available models
Tip: use --model'
assert gpt "只有非 gpt -> 空" "" 'claude-opus-4-8-max - X'
assert gpt "垃圾输入 -> 空" "" 'garbage nonsense'

# ─────────────────────────── 运行时失败路径 ───────────────────────────
WORK=$(mktemp -d)
STUB="$WORK/stubbin"; mkdir -p "$STUB"
echo "hello" > "$WORK/p.txt"

make_stub() { # $1 = list 行为: hang | partial-fail | auth-fail | quota-fail | ok
  cat > "$STUB/cursor-agent" <<EOF
#!/usr/bin/env bash
MODE="$1"
if [ "\$1" = "--list-models" ]; then
  case "$1" in
    hang)         sleep 300 ;;
    partial-fail) echo "Available models"; echo "gemini-9.9-evil-pro - Evil"; exit 7 ;;
    auth-fail)    echo "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable." >&2
                  exit 1 ;;
    ok|quota-fail) echo "Available models"
                  echo "gpt-5.6-sol-high - GPT"
                  echo "gemini-3.1-pro - Gemini"
                  echo "gemini-3.1-pro-max - Gemini Max"
                  echo "cursor-grok-4.6-high - Grok" ;;
  esac
  exit 0
fi
# 额度耗尽时 --list-models 照样成功（2026-08-30 实测 206 行），只有真调用才撞墙。
# 夹具必须复刻这个不对称，否则测不出"快检抓不到额度"这个真实缺陷
if [ "\$MODE" = "quota-fail" ]; then
  echo "ActionRequiredError: You've hit your usage limit You've saved \$NNN on API model usage this month with <plan>. Switch to a different model or set a Spend Limit to continue with this model. Your usage limits will reset when your monthly cycle ends on 1/31/2099." >&2
  exit 1
fi
while [ \$# -gt 0 ]; do [ "\$1" = "--model" ] && echo "USED_MODEL=\$2"; [ "\$1" = "--workspace" ] && echo "USED_WORKSPACE=\$2"; shift; done
EOF
  chmod +x "$STUB/cursor-agent"
}

make_list_stub() { # $1 = 模型列表文件：--list-models 原样吐它，正式调用回显实际 --model
  cat > "$STUB/cursor-agent" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--list-models" ]; then cat "$1"; exit 0; fi
while [ \$# -gt 0 ]; do [ "\$1" = "--model" ] && echo "USED_MODEL=\$2"; shift; done
EOF
  chmod +x "$STUB/cursor-agent"
}

check() { # <name> <expect-substr> <actual>
  case "$3" in *"$2"*) echo "PASS  $1";; *) echo "FAIL  $1: 期望含 '$2'，实得: $3"; fail=1;; esac
}

echo "=== 负例：check 对不含期望子串的输出必须报 FAIL ==="
NEG=$( fail=0; check "故意不匹配" "NOT-THERE" "some output"; echo "fail=$fail" )
case "$NEG" in *"FAIL  故意不匹配"*"fail=1") echo "PASS  check 不匹配 -> FAIL 且 fail=1";; *) echo "FAIL  check 没有报失败: $NEG"; fail=1;; esac

echo "=== 运行时 0：三族都走 cursor（gpt 不再被拒）；族参数必须显式给 ==="
make_list_stub "$FULL_LIST"
for f in gpt gemini grok; do
  case "$f" in gpt) want=gpt-5.6-sol-xhigh;; gemini) want=gemini-4-neon-xhigh;; grok) want=grok-4.7-xhigh;; esac
  OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o0-$f.txt" "$f" 2>&1); RC=$?
  [ "$RC" = "0" ] && echo "PASS  $f -> exit 0" || { echo "FAIL  $f 应 exit 0，实得 $RC: $OUT"; fail=1; }
  check "$f 端到端调用用的是解析结果" "USED_MODEL=$want" "$(cat "$WORK/o0-$f.txt" 2>/dev/null)"
done
OUT=$(SURVEY_CURSOR_EFFORT=high PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gpt 2>/dev/null)
[ "$OUT" = "gpt-5.6-sol-high" ] && echo "PASS  SURVEY_CURSOR_EFFORT=high 对 gpt 生效" || { echo "FAIL  gpt high: 实得 '$OUT'"; fail=1; }
OUT=$(SURVEY_CURSOR_EFFORT=high PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>/dev/null)
[ "$OUT" = "gemini-4-neon-high" ] && echo "PASS  SURVEY_CURSOR_EFFORT=high 对 gemini 生效" || { echo "FAIL  gemini high: 实得 '$OUT'"; fail=1; }
OUT=$(SURVEY_SERIES_GEMINI='hydrogen neon' PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>/dev/null)
[ "$OUT" = "gemini-4-hydrogen-xhigh" ] && echo "PASS  SURVEY_SERIES_GEMINI 端到端生效" || { echo "FAIL  系列覆盖: 实得 '$OUT'"; fail=1; }
PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o0b.txt" >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  缺族参数 -> exit 64（没有默认族）" || { echo "FAIL  缺族参数应 exit 64"; fail=1; }
PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only codex >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  --resolve-only codex -> exit 64（codex 不是本脚本的族）" || { echo "FAIL  --resolve-only codex 应 exit 64"; fail=1; }

echo "=== 运行时 0.5：列表缩水 vs 该族下架——文案区分，两种都 fail-closed ==="
make_list_stub "$SHRUNK_LIST"
for f in gpt gemini; do
  rm -f "$WORK/sh-$f.txt"
  OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/sh-$f.txt" "$f" 2>&1); RC=$?
  [ "$RC" = "65" ] && echo "PASS  缩水列表下 $f -> exit 65" || { echo "FAIL  缩水 $f 期望 65 实得 $RC"; fail=1; }
  check "缩水列表下 $f 报'疑似临时缩水'" "疑似临时缩水" "$OUT"
  case "$OUT" in *可能已下架*) echo "FAIL  缩水被误报成下架"; fail=1;; *) echo "PASS  缩水未被说成下架";; esac
  grep -q USED_MODEL "$WORK/sh-$f.txt" 2>/dev/null && { echo "FAIL  缩水时仍发起了调用"; fail=1; } || echo "PASS  缩水时未发起调用（fail-closed）"
  OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only "$f" 2>"$WORK/sh-ro.err"); RC=$?
  check "缩水时 --resolve-only $f 的 stderr 也报'疑似临时缩水'（doctor 据此改文案）" "疑似临时缩水" "$(cat "$WORK/sh-ro.err")"
done
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only grok 2>/dev/null)
[ "$OUT" = "grok-4.7-xhigh" ] && echo "PASS  缩水列表下 grok 照常解析" || { echo "FAIL  缩水 grok: 实得 '$OUT'"; fail=1; }
grep -v '^gemini-' "$FULL_LIST" > "$WORK/no-gemini.txt"
make_list_stub "$WORK/no-gemini.txt"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/delisted.txt" gemini 2>&1); RC=$?
[ "$RC" = "65" ] && echo "PASS  完整列表但无 gemini -> exit 65" || { echo "FAIL  下架期望 65 实得 $RC"; fail=1; }
check "完整列表无该族 -> 报'可能已下架'" "可能已下架" "$OUT"
case "$OUT" in *疑似临时缩水*) echo "FAIL  下架被误报成缩水"; fail=1;; *) echo "PASS  下架未被说成缩水";; esac

echo "=== 运行时 1：--list-models 挂起 -> deadline -> fallback ==="
make_stub hang
T0=$(date +%s)
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o1.txt" gemini 2>&1)
EL=$(( $(date +%s) - T0 ))
check "挂起时打 WARN" "取模型列表失败或超时" "$OUT"
check "挂起时回落 fallback" "MODEL: $FB_GEMINI" "$OUT"
check "实际调用用了 fallback" "USED_MODEL=$FB_GEMINI" "$(cat "$WORK/o1.txt")"
if [ "$EL" -ge 18 ] && [ "$EL" -le 32 ]; then echo "PASS  deadline 生效（${EL}s ≈ 20s）"; else echo "FAIL  deadline 未按 20s 生效: ${EL}s"; fail=1; fi

echo "=== 运行时 2：列表非零退出但有部分输出 -> 必须丢弃 ==="
make_stub partial-fail
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o2.txt" gemini 2>&1)
check "不采用残缺列表里的 gemini-9.9-evil" "MODEL: $FB_GEMINI" "$OUT"
case "$OUT" in *evil*) echo "FAIL  残缺列表被采用了"; fail=1;; *) echo "PASS  残缺列表已丢弃";; esac

echo "=== 运行时 2.5：认证失效 -> fail-closed exit 67，不许洗成超时 ==="
make_stub auth-fail
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o25.txt" gemini 2>&1); RC=$?
if [ "$RC" -eq 67 ]; then echo "PASS  认证失效 -> exit 67"; else echo "FAIL  认证失效应 exit 67，实得 $RC"; fail=1; fi
check "认证失效打出可执行的修复指引" "cursor-agent login" "$OUT"
check "认证失效透传 CLI 原始 stderr" "Authentication required" "$OUT"
case "$OUT" in *取模型列表失败或超时*) echo "FAIL  auth 失败被洗成了超时文案"; fail=1;; *) echo "PASS  未把 auth 失败洗成超时";; esac
case "$OUT" in *"MODEL: $FB_GEMINI"*) echo "FAIL  认证失效仍回落到 fallback（应 fail-closed）"; fail=1;; *) echo "PASS  认证失效未静默回落";; esac
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>&1); RC=$?
if [ "$RC" -eq 67 ]; then echo "PASS  --resolve-only 认证失效也 exit 67"; else echo "FAIL  --resolve-only 应 exit 67，实得 $RC"; fail=1; fi

echo "=== 运行时 2.6：额度耗尽 -> exit 68 + 写状态文件，且不得与认证混淆 ==="
QSTATE_DIR="$WORK/state"
rm -rf "$QSTATE_DIR"
make_stub quota-fail
OUT=$(SURVEY_STATE_DIR="$QSTATE_DIR" PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o26.txt" gemini 2>&1); RC=$?
if [ "$RC" -eq 68 ]; then echo "PASS  额度耗尽 -> exit 68"; else echo "FAIL  额度耗尽应 exit 68，实得 $RC"; fail=1; fi
check "额度耗尽说清是额度问题" "撞到 Cursor 月度额度上限" "$OUT"
check "额度耗尽给出三条出路" "on-demand" "$OUT"
case "$OUT" in *认证失效*) echo "FAIL  额度被误分类成认证失效"; fail=1;; *) echo "PASS  未与认证混淆";; esac
check "额度耗尽时模型仍能实时解析（证明 list-models 抓不到额度）" "MODEL: gemini-3.1-pro" "$OUT"
if [ -s "$QSTATE_DIR/quota-state" ]; then
  echo "PASS  额度留痕已写入状态文件"
  check "留痕含族名" "gemini" "$(cat "$QSTATE_DIR/quota-state")"
  check "留痕含重置日" "1/31/2099" "$(cat "$QSTATE_DIR/quota-state")"
else
  echo "FAIL  额度留痕未写入 $QSTATE_DIR/quota-state"; fail=1
fi
make_stub ok
OUT=$(SURVEY_STATE_DIR="$QSTATE_DIR" PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o27.txt" gemini 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then echo "PASS  额度恢复后调用成功"; else echo "FAIL  恢复后应 exit 0，实得 $RC"; fail=1; fi
if [ -s "$QSTATE_DIR/quota-state" ]; then
  echo "FAIL  成功调用后留痕仍在（doctor 会继续误报）：$(cat "$QSTATE_DIR/quota-state")"; fail=1
else
  echo "PASS  成功调用清掉了该族留痕"
fi

echo "=== 运行时 3：family 参数 + 空 workspace 隔离 ==="
make_stub ok
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o3.txt" gemini 2>&1)
check "family=gemini 选 gemini" "MODEL: gemini-3.1-pro (family=gemini)" "$OUT"
check "调用带 --workspace（空目录，不把 cwd 的 rules/AGENTS.md 注入 lens）" "USED_WORKSPACE=" "$(cat "$WORK/o3.txt")"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o5.txt" grok 2>&1)
check "family=grok 选 grok" "MODEL: cursor-grok-4.6-high (family=grok)" "$OUT"
PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o6.txt" llama >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  非法 family -> exit 64" || { echo "FAIL  非法 family 未 exit 64"; fail=1; }

echo "=== 运行时 3.5：幽灵 id fail-closed（fallback 不在实时列表就不调用）==="
cat > "$STUB/cursor-agent" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--list-models" ]; then echo "Available models"; echo "gemini-4.0-flash-high - only flash left"; exit 0; fi
echo "SHOULD-NOT-BE-CALLED"
EOF
chmod +x "$STUB/cursor-agent"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o35.txt" gemini 2>&1); RC=$?
[ "$RC" = "65" ] && echo "PASS  fallback 不在实时列表 -> exit 65，不烧调用" || { echo "FAIL  期望 65 实得 $RC"; fail=1; }
check "说明是'不在实时列表'" "不在实时列表" "$OUT"
[ -f "$WORK/o35.txt" ] && grep -q SHOULD-NOT-BE-CALLED "$WORK/o35.txt" && { echo "FAIL  幽灵 id 仍发起了调用"; fail=1; } || echo "PASS  未发起调用"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>"$WORK/ro35.err"); RC=$?
[ "$RC" = "0" ] && echo "PASS  --resolve-only 仍 exit 0 打 id（由 doctor 复核并给修复建议）" || { echo "FAIL  resolve-only 期望 0 实得 $RC"; fail=1; }
check "resolve-only 的 stderr 带'不在实时列表' WARN" "不在实时列表" "$(cat "$WORK/ro35.err")"

echo "=== 运行时 4：[reviewer] 跨族钉值必须被硬拦（否则 tiebreaker 变红队自审）==="
make_stub ok
OUT=$(SURVEY_CURSOR_MODEL='cursor-grok-4.6-high' PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/ox.txt" gemini 2>&1)
check "grok 钉值带到 gemini 调用 -> 被拒" "不属于 family=gemini" "$OUT"
check "被拒后改用 gemini 自动解析" "MODEL: gemini-3.1-pro (family=gemini)" "$OUT"
case "$(cat "$WORK/ox.txt")" in *grok*) echo "FAIL  实际调用仍是 grok——异族裁决失效"; fail=1;; *) echo "PASS  实际调用未串到 grok";; esac
OUT=$(SURVEY_CURSOR_MODEL='gemini-3.1-pro-max' PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/oy.txt" gemini 2>&1)
check "同族钉值正常生效（可强上 max）" "MODEL: gemini-3.1-pro-max (family=gemini)" "$OUT"
OUT=$(SURVEY_CURSOR_MODEL='gemini-3.1-pro' PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gpt 2>&1)
check "gemini 钉值带到 gpt 调用 -> 被拒" "不属于 family=gpt" "$OUT"
OUT=$(SURVEY_CURSOR_MODEL='gpt-5.6-sol-high' PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only grok 2>&1)
check "gpt 钉值带到 grok 调用 -> 被拒" "不属于 family=grok" "$OUT"
OUT=$(SURVEY_CURSOR_MODEL='gpt-5.6-sol-high' PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gpt 2>&1)
check "gpt 同族钉值生效" "MODEL: gpt-5.6-sol-high (family=gpt)" "$OUT"
# [reviewer] 上一条钉的 id 恰好等于自动解析结果，钉值被错拒也照样 PASS。
# 这里在完整列表下钉一个与自动解析（各族的 *-xhigh 首选）不同的同族 id：被拒就会露出来
make_list_stub "$FULL_LIST"
for fm in gpt:gpt-5.6-terra-high gemini:gemini-4-hydrogen-high grok:cursor-grok-4.6-high; do
  f=${fm%%:*}; m=${fm#*:}
  OUT=$(SURVEY_CURSOR_MODEL="$m" PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only "$f" 2>"$WORK/pin.err")
  [ "$OUT" = "$m" ] && echo "PASS  $f 同族钉值（≠自动解析）stdout = $m" || { echo "FAIL  $f 同族钉值期望 stdout=$m 实得: $OUT"; fail=1; }
  case "$(cat "$WORK/pin.err")" in *"不属于 family"*) echo "FAIL  $f 同族钉值被误拒: $(cat "$WORK/pin.err")"; fail=1;; *) echo "PASS  $f 同族钉值未被判跨族";; esac
done
make_stub ok
for m in grok-4.7-high cursor-grok-4.6-high; do
  OUT=$(SURVEY_CURSOR_MODEL="$m" PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only grok 2>&1)
  check "grok 钉值接受前缀写法 $m" "MODEL: $m (family=grok)" "$OUT"
done

echo "=== 运行时 5：SURVEY_CURSOR_MODEL 校验 ==="
OUT=$(SURVEY_CURSOR_MODEL='bad;rm -rf /
x' PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o8.txt" gemini 2>&1)
check "非法字符被拒" "含非法字符" "$OUT"
check "拒绝后回到自动解析" "MODEL: gemini-3.1-pro" "$OUT"
OUT=$(SURVEY_CURSOR_MODEL='' PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o9.txt" gemini 2>&1)
check "空值走自动解析" "MODEL: gemini-3.1-pro" "$OUT"

echo "=== 运行时 6：[reviewer] 正式调用挂起 -> 内置 watchdog 兜底（不依赖系统 timeout）==="
cat > "$STUB/cursor-agent" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--list-models" ]; then echo "gemini-3.1-pro - G"; exit 0; fi
sleep 300   # 模拟正式调用挂死
EOF
chmod +x "$STUB/cursor-agent"
T0=$(date +%s)
( PATH="$STUB:$PATH" SURVEY_TIMEOUT_SEC=5 bash "$SCRIPT" "$WORK/p.txt" "$WORK/oz.txt" gemini ) >/dev/null 2>"$WORK/wd.err"
WD_EXIT=$?
EL=$(( $(date +%s) - T0 ))
[ "$WD_EXIT" = "124" ] && echo "PASS  挂死被 watchdog 杀掉，exit 124" || { echo "FAIL  期望 124 实得 $WD_EXIT"; fail=1; }
if [ "$EL" -le 20 ]; then echo "PASS  watchdog 及时触发（${EL}s）"; else echo "FAIL  watchdog 过慢: ${EL}s"; fail=1; fi

echo "=== 运行时 7：临时文件不残留 ==="
LEFT=$(ls -d "${TMPDIR:-/tmp}"/survey-models.* "${TMPDIR:-/tmp}"/survey-cursor-agent.* 2>/dev/null | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] && echo "PASS  无临时文件残留" || { echo "FAIL  残留 $LEFT 个临时文件/目录"; fail=1; }

echo "=== 运行时 8：--resolve-only（doctor.sh 复用生产解析逻辑的探针模式）==="
make_stub ok
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>"$WORK/ro.err")
check "resolve-only 打印裸模型 id 到 stdout" "gemini-3.1-pro" "$OUT"
case "$OUT" in *USED_MODEL*) echo "FAIL  resolve-only 竟发起了正式调用"; fail=1;; *) echo "PASS  resolve-only 未发起正式调用";; esac
check "stderr 仍打 MODEL 行（doctor 靠 WARN 有无区分 fallback）" "MODEL: gemini-3.1-pro (family=gemini)" "$(cat "$WORK/ro.err")"
PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only llama >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  resolve-only 非法 family -> exit 64" || { echo "FAIL  resolve-only 非法 family 未 exit 64"; fail=1; }
PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini extra >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  resolve-only 多余参数 -> exit 64" || { echo "FAIL  resolve-only 多余参数未 exit 64"; fail=1; }
OUT=$(SURVEY_CURSOR_MODEL='gemini-3.1-pro-max' PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>/dev/null)
check "resolve-only 尊重同族钉值" "gemini-3.1-pro-max" "$OUT"
cat > "$STUB/cursor-agent" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--list-models" ]; then
  echo "cursor-grok-4.6-xhigh - Grok XH"; echo "cursor-grok-4.6-high - Grok H"; exit 0
fi
EOF
chmod +x "$STUB/cursor-agent"
OUT=$(SURVEY_CURSOR_EFFORT=high PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only grok 2>/dev/null)
check "SURVEY_CURSOR_EFFORT=high 端到端生效" "cursor-grok-4.6-high" "$OUT"
OUT=$(SURVEY_CURSOR_EFFORT=banana PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only grok 2>&1 >/dev/null)
check "非法 effort 打 WARN 回落 xhigh" "SURVEY_CURSOR_EFFORT" "$OUT"
LEFT=$(ls "${TMPDIR:-/tmp}"/survey-models.* 2>/dev/null | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] && echo "PASS  resolve-only 无临时文件残留" || { echo "FAIL  resolve-only 残留 $LEFT 个临时文件"; fail=1; }

echo "=== 运行时 9：async job（start/status/wait 三段式，nohup 脱离进程树，按族路由）==="
ASYNC="$(cd "$(dirname "$0")" && pwd)/run-agent-async.sh"
make_stub ok
# 9a: 正常 job 走完 → DONE，输出落盘
JOB=$(PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-out.txt" gemini 60)
sleep 3
OUT=$(bash "$ASYNC" wait "$JOB" 30); WEXIT=$?
check "async 正常完成 -> DONE" "DONE" "$OUT"
[ "$WEXIT" = "0" ] && echo "PASS  wait 完成 exit 0" || { echo "FAIL  wait 期望 0 实得 $WEXIT"; fail=1; }
check "async 输出落盘（stub 记录了实际模型）" "USED_MODEL=gemini-3.1-pro" "$(cat "$WORK/async-out.txt" 2>/dev/null)"
check "job.meta 记录了路由到的 runner" "runner=run-cursor-agent.sh" "$(cat "$JOB/job.meta")"
# 9a': gpt 族在 async 入口路由到 cursor runner；codex 仍路由到 run-codex.sh；族参数缺失拒绝
JOB=$(PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-gpt.txt" gpt 60)
OUT=$(bash "$ASYNC" wait "$JOB" 30)
check "async gpt -> DONE" "DONE" "$OUT"
check "async gpt 路由到 run-cursor-agent.sh" "runner=run-cursor-agent.sh" "$(cat "$JOB/job.meta" 2>/dev/null)"
check "async gpt 实际调用的是 gpt 族模型" "USED_MODEL=gpt-5.6-sol-high" "$(cat "$WORK/async-gpt.txt" 2>/dev/null)"
# codex 路由只验 job.meta，不真调：PATH 里放一个假 codex，runner 无论走到哪一步都碰不到真 CLI（零配额）
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/codex"; chmod +x "$STUB/codex"
JOB=$(PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-codex.txt" codex 10)
check "async codex 仍路由到 run-codex.sh（备用通道）" "runner=run-codex.sh" "$(cat "$JOB/job.meta" 2>/dev/null)"
bash "$ASYNC" wait "$JOB" 30 >/dev/null 2>&1
rm -f "$STUB/codex"
PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-nofam.txt" >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  async start 缺族 -> exit 64" || { echo "FAIL  async 缺族应 exit 64"; fail=1; }
# 9b: 挂死 job 被 deadline 杀 → FAILED exit=124
cat > "$STUB/cursor-agent" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--list-models" ]; then echo "gemini-3.1-pro - G"; exit 0; fi
sleep 300
EOF
chmod +x "$STUB/cursor-agent"
T0=$(date +%s)
JOB=$(PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-oz.txt" gemini 6)
OUT=$(bash "$ASYNC" wait "$JOB" 40); WEXIT=$?
EL=$(( $(date +%s) - T0 ))
check "挂死 job 被 deadline 杀 -> FAILED exit=124" "FAILED exit=124" "$OUT"
[ "$WEXIT" = "4" ] && echo "PASS  wait 对失败 job exit 4" || { echo "FAIL  期望 4 实得 $WEXIT"; fail=1; }
if [ "$EL" -le 30 ]; then echo "PASS  deadline 及时触发（${EL}s）"; else echo "FAIL  deadline 过慢: ${EL}s"; fail=1; fi
# 9c: wait 波次到点未完 -> exit 3（RUNNING），再等最终完成
JOB=$(PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-o3.txt" gemini 25)
OUT=$(bash "$ASYNC" wait "$JOB" 5); WEXIT=$?
check "波次到点未完 -> RUNNING" "RUNNING" "$OUT"
[ "$WEXIT" = "3" ] && echo "PASS  未完波次 exit 3（可续杯）" || { echo "FAIL  期望 3 实得 $WEXIT"; fail=1; }
bash "$ASYNC" wait "$JOB" 60 >/dev/null 2>&1   # 收尾：等 deadline 杀掉它，不留孤儿

echo "=== 运行时 10：排名文件端到端（runner 的 NEW-MODEL / 保底 WARN；doctor 汇总，不改 verdict）==="
{ cat "$FULL_LIST"; echo "gpt-6.2-astra-high - New GPT"; echo "gemini-4-xenon-xhigh - New Gemini"; } > "$WORK/with-new.txt"
make_list_stub "$WORK/with-new.txt"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gpt 2>"$WORK/nm.err")
[ "$OUT" = "gpt-6.2-astra-high" ] && echo "PASS  runner：更高版本的新模型被解析出来" || { echo "FAIL  runner 新版本: 实得 '$OUT'"; fail=1; }
check "runner：stderr 有 NEW-MODEL 行" "NEW-MODEL: [gpt] gpt-6.2-astra 未在排名文件中核实" "$(cat "$WORK/nm.err")"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>"$WORK/nm.err")
[ "$OUT" = "gemini-4-neon-xhigh" ] && echo "PASS  runner：同版本新系列未被选中" || { echo "FAIL  runner 新系列: 实得 '$OUT'"; fail=1; }
check "runner：同版本新系列仍有 NEW-MODEL 行" "NEW-MODEL: [gemini] gemini-4-xenon 未在排名文件中核实" "$(cat "$WORK/nm.err")"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/nm-run.txt" gpt 2>&1); RC=$?
[ "$RC" = "0" ] && echo "PASS  runner：有新模型时正式调用照常 exit 0" || { echo "FAIL  期望 0 实得 $RC"; fail=1; }
check "runner：正式调用用的是新模型" "USED_MODEL=gpt-6.2-astra-high" "$(cat "$WORK/nm-run.txt" 2>/dev/null)"
OUT=$(SURVEY_CURSOR_MODEL=gpt-5.6-sol-high PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gpt 2>"$WORK/nm.err")
[ "$OUT" = "gpt-5.6-sol-high" ] && echo "PASS  runner：钉值仍然生效" || { echo "FAIL  钉值: 实得 '$OUT'"; fail=1; }
check "runner：钉了旧模型也照样提示新模型" "NEW-MODEL: [gpt] gpt-6.2-astra" "$(cat "$WORK/nm.err")"
make_list_stub "$FULL_LIST"
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>"$WORK/nm.err")
case "$(cat "$WORK/nm.err")" in *NEW-MODEL*|*排名文件*) echo "FAIL  runner：完整列表不应有排名相关提示: $(cat "$WORK/nm.err")"; fail=1;; *) echo "PASS  runner：完整列表 + 缺省排名文件 -> 无提示";; esac
OUT=$(SURVEY_RANKING_FILE="$WORK/no-such.conf" PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gemini 2>"$WORK/nm.err"); RC=$?
[ "$RC" = "0" ] && [ "$OUT" = "gemini-4-neon-xhigh" ] && echo "PASS  runner：排名文件缺失 -> 保底顺序照常解析" || { echo "FAIL  缺失: rc=$RC out='$OUT'"; fail=1; }
check "runner：排名文件缺失 -> WARN" "WARN: [gemini] 排名文件" "$(cat "$WORK/nm.err")"
case "$(cat "$WORK/nm.err")" in *回落到*) echo "FAIL  排名保底被说成了模型回落（doctor 会误判 fallback）"; fail=1;; *) echo "PASS  排名保底的 WARN 不含'回落到'";; esac

# doctor：PATH 收窄到 stub + 系统目录（碰不到真 cursor-agent / codex，零配额零网络），状态目录隔离
DOCTOR="$HERE/doctor.sh"
DPATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin"
TODAY=$(date +%Y-%m-%d)
sed "s/^checked .*/checked  = $TODAY/" "$RANKING" > "$WORK/fresh.conf"
sed "s/^checked .*/checked  = 2020-01-01/" "$RANKING" > "$WORK/stale.conf"
run_doctor() { # <排名文件> -> stdout 落 $WORK/doc.out，返回 doctor 的 exit code
  SURVEY_RANKING_FILE="$1" SURVEY_STATE_DIR="$WORK/doc-state" PATH="$DPATH" bash "$DOCTOR" > "$WORK/doc.out" 2>&1
}
run_doctor "$WORK/fresh.conf"; RC=$?
[ "$RC" = "0" ] && echo "PASS  doctor：全是已核实模型 + 日期新 -> exit 0" || { echo "FAIL  doctor 基线期望 0 实得 $RC: $(cat "$WORK/doc.out")"; fail=1; }
check "doctor：基线报「没有未核实的新模型」" "没有未核实的新模型" "$(cat "$WORK/doc.out")"
case "$(cat "$WORK/doc.out")" in *NEW-MODEL*|*核对日期超过*) echo "FAIL  doctor 基线不应有排名告警"; fail=1;; *) echo "PASS  doctor：基线没有排名告警";; esac
make_list_stub "$WORK/with-new.txt"
run_doctor "$WORK/fresh.conf"; RC=$?
check "doctor：新模型 -> [WARN] 带 NEW-MODEL 行（gpt）" "[WARN]  NEW-MODEL: [gpt] gpt-6.2-astra" "$(cat "$WORK/doc.out")"
check "doctor：新模型 -> [WARN] 带 NEW-MODEL 行（gemini）" "[WARN]  NEW-MODEL: [gemini] gemini-4-xenon" "$(cat "$WORK/doc.out")"
check "doctor：修复建议写明要上网核实并更新三样" "上网核实后更新 model-ranking.conf 的顺序、清单和核对日期" "$(cat "$WORK/doc.out")"
check "doctor：新模型不改 verdict" "VERDICT: HEALTHY" "$(cat "$WORK/doc.out")"
[ "$RC" = "0" ] && echo "PASS  doctor：新模型时 exit 仍为 0" || { echo "FAIL  doctor 新模型期望 0 实得 $RC"; fail=1; }
make_list_stub "$FULL_LIST"
run_doctor "$WORK/stale.conf"; RC=$?
check "doctor：核对日期过期 -> WARN" "[WARN]  模型排名的核对日期超过 60 天" "$(cat "$WORK/doc.out")"
check "doctor：过期 WARN 点名族与日期" "gpt(2020-01-01" "$(cat "$WORK/doc.out")"
check "doctor：过期也给同一条修复建议" "上网核实后更新 model-ranking.conf 的顺序、清单和核对日期" "$(cat "$WORK/doc.out")"
[ "$RC" = "0" ] && echo "PASS  doctor：日期过期不改 verdict（exit 0）" || { echo "FAIL  doctor 过期期望 0 实得 $RC"; fail=1; }
run_doctor "$WORK/no-such.conf"; RC=$?
check "doctor：排名文件缺失 -> WARN" "[WARN]  排名文件" "$(cat "$WORK/doc.out")"
[ "$RC" = "0" ] && echo "PASS  doctor：排名文件缺失不改 verdict（exit 0）" || { echo "FAIL  doctor 缺失期望 0 实得 $RC: $(cat "$WORK/doc.out")"; fail=1; }


echo "=== 运行时 11：[reviewer 2026-11-19] 硬约束在默认流程里触发得到 ==="
# 11a doctor：选型规则不收的新形态不许再报「没有未核实的新模型」
{ cat "$FULL_LIST"; echo "gemini-5-high - x"; echo "gpt-6-max - x"; echo "gpt-6 - x"; echo "xai-grok-5-high - x"; } > "$WORK/with-odd.txt"
make_list_stub "$WORK/with-odd.txt"
run_doctor "$WORK/fresh.conf"; RC=$?
check "doctor：gemini-5-high（无系列）-> NEW-MODEL" "[WARN]  NEW-MODEL: [gemini] gemini-5 " "$(cat "$WORK/doc.out")"
check "doctor：gpt-6 / gpt-6-max -> NEW-MODEL" "[WARN]  NEW-MODEL: [gpt] gpt-6 " "$(cat "$WORK/doc.out")"
check "doctor：xai-grok-5-high -> NEW-MODEL" "[WARN]  NEW-MODEL: [grok] xai-grok-5 " "$(cat "$WORK/doc.out")"
case "$(cat "$WORK/doc.out")" in *"没有未核实的新模型"*) echo "FAIL  doctor 在有新模型时仍报「没有未核实的新模型」"; fail=1;; *) echo "PASS  doctor：有新模型时不再报「没有未核实的新模型」";; esac
[ "$RC" = "0" ] && echo "PASS  doctor：exit 仍为 0（所以 02-research 要求 exit 0 也看 L3.2）" || { echo "FAIL  期望 0 实得 $RC"; fail=1; }
# 11b doctor：排名文件写错 -> WARN，不报 PASS
make_list_stub "$FULL_LIST"
sed "s/^series   = neon/serise   = neon/" "$WORK/fresh.conf" > "$WORK/typo.conf"
run_doctor "$WORK/typo.conf"
check "doctor：键名拼错 -> [WARN]" "[WARN]  WARN: [gemini] 排名文件" "$(cat "$WORK/doc.out")"
case "$(cat "$WORK/doc.out")" in *"没有未核实的新模型"*) echo "FAIL  doctor 在排名文件写错时仍报 PASS"; fail=1;; *) echo "PASS  doctor：排名文件写错时不报 PASS";; esac
sed "s/^checked  = /Checked = /; s/^\\[grok\\]/[Grok]/" "$WORK/fresh.conf" > "$WORK/case.conf"
run_doctor "$WORK/case.conf"
check "doctor：Checked / [Grok] 大小写不同 -> 日期照样读得到" "没有未核实的新模型；三族核对日期均在 60 天内" "$(cat "$WORK/doc.out")"
# 11c async：job.log 里的 NEW-MODEL 必须跟着状态行回显（主 Claude 只看得到 wait / status 的输出）
make_list_stub "$WORK/with-new.txt"
JOB=$(PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-nm.txt" gpt 30)
OUT=$(bash "$ASYNC" wait "$JOB" 20); WEXIT=$?
check "async：wait 的 DONE 输出带 MODEL 行" "MODEL: gpt-6.2-astra-high" "$OUT"
check "async：wait 的输出回显 NEW-MODEL" "NEW-MODEL: [gpt] gpt-6.2-astra 未在排名文件中核实" "$OUT"
[ "$WEXIT" = "0" ] && echo "PASS  async：回显不改 exit code" || { echo "FAIL  期望 0 实得 $WEXIT"; fail=1; }
check "async：status 同样回显" "NEW-MODEL: [gpt] gpt-6.2-astra" "$(bash "$ASYNC" status "$JOB")"
make_list_stub "$FULL_LIST"
JOB=$(PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-nm2.txt" gpt 30)
OUT=$(bash "$ASYNC" wait "$JOB" 20)
[ "$(printf '%s\n' "$OUT" | grep -c .)" = "1" ] && echo "PASS  async：没有提示时仍只有一行状态" || { echo "FAIL  async 无提示时多打了行: $OUT"; fail=1; }
# 11d doctor 修复建议：在生成的镜像里跑时必须指向 .rulesync 源（改镜像会被 ai:generate 覆盖）
REPO="$WORK/repo"; mkdir -p "$REPO/.claude/skills" "$REPO/.rulesync/skills"
cp -R "$HERE" "$REPO/.claude/skills/survey"; cp -R "$HERE" "$REPO/.rulesync/skills/survey"
make_list_stub "$WORK/with-new.txt"
doctor_in() { # <skill 目录>：不设 SURVEY_RANKING_FILE（设了就是显式指定，不做源/镜像推断）
  env -u SURVEY_RANKING_FILE SURVEY_STATE_DIR="$WORK/doc-state" PATH="$DPATH" bash "$1/doctor.sh" > "$WORK/doc.out" 2>&1
}
doctor_in "$REPO/.claude/skills/survey"
check "doctor（镜像里跑）：修复建议给的是源文件路径" "/repo/.rulesync/skills/survey/model-ranking.conf" "$(grep '上网核实后更新' "$WORK/doc.out")"
check "doctor（镜像里跑）：写明改完要重新生成" "pnpm run ai:generate" "$(grep '上网核实后更新' "$WORK/doc.out")"
case "$(grep '上网核实后更新' "$WORK/doc.out")" in *"要改的文件: "*"/repo/.claude/skills/survey/model-ranking.conf"*) echo "FAIL  doctor 仍让人改镜像"; fail=1;; *) echo "PASS  doctor（镜像里跑）：没有让人改镜像文件";; esac
doctor_in "$REPO/.rulesync/skills/survey"
check "doctor（源里跑）：修复建议给的是本目录的文件" "/repo/.rulesync/skills/survey/model-ranking.conf" "$(grep '上网核实后更新' "$WORK/doc.out")"
case "$(grep '上网核实后更新' "$WORK/doc.out")" in *"生成的镜像"*) echo "FAIL  doctor 在源目录里却说这是镜像"; fail=1;; *) echo "PASS  doctor（源里跑）：不提镜像";; esac
# 11e 文档与流程对得上（三处原来对不上：02 只管非 0、04 没有字段、SKILL.md 没说改源）
check "02-research：doctor exit 0 也要看 L3.2" "exit 0 也要看 L3.2" "$(cat "$HERE/phases/02-research.md")"
check "04-synthesis：写报告步骤有 模型排名 字段" '`模型排名: <已核实 YYYY-MM-DD / 未核实' "$(cat "$HERE/phases/04-synthesis.md")"
check "04-synthesis：报告模板 §metadata 有 模型排名 字段" '- **模型排名**: ' "$(cat "$HERE/phases/04-synthesis.md")"
check "SKILL.md：硬约束写明改 .rulesync 源" ".rulesync/skills/survey/model-ranking.conf" "$(grep '模型排名要查证' "$HERE/SKILL.md")"
check "SKILL.md：硬约束写明异步 job 去哪看" "异步 job" "$(grep '模型排名要查证' "$HERE/SKILL.md")"

rm -rf "$WORK"
exit $fail
