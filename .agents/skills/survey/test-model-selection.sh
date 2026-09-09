#!/usr/bin/env bash
# /survey — 模型选择逻辑的可执行断言（配合 run-cursor-agent.sh §模型选择）
#
# 为什么要有这个文件：模型不再钉版本，靠启发式跟 Cursor 的 model id 命名走。
# Cursor 一旦改命名（新代号 / 新 effort 档 / 新形态），启发式就可能选错——这里
# 用固定 fixture 把"该选什么/不该选什么"钉成断言，改规则前先跑一遍。
#   [reviewer] = 2026-07-21 两个异构 reviewer(gpt-5.6-sol-max / -xhigh) 给出的反例
#   [regress]  = 实际踩过的 bug，改规则时别再踩回去
#
# 2026-09-09：gpt 族在 cursor 通道退役（改走 run-codex.sh，见 test-run-codex.sh）。
# pick_strongest 的 gpt 分支保留用于下面的**通用规则**断言（排除项/版本比较/档位偏好都是
# 族无关逻辑，用 gpt fixture 测最省事）；运行时用例改用 gemini/grok，并新增"gpt → 64 指路"。
#
# 跑：bash test-model-selection.sh   （全绿 exit 0；live 那几条需要已登录的 cursor-agent）

set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/run-cursor-agent.sh"
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
FB_GEMINI=$(fallback_of gemini); FB_GROK=$(fallback_of grok)
[ -n "$FB_GEMINI" ] && [ -n "$FB_GROK" ] || { echo "FAIL  读不到实现里的 FALLBACK_MODEL 常量（case 分支格式变了？）"; fail=1; }

assert() { # <family> <name> <expected> <input>
  got=$(printf '%s\n' "$4" | pick_strongest "$1")
  if [ "$got" = "$3" ]; then echo "PASS  [$1] $2 -> ${got:-<empty>}"
  else echo "FAIL  [$1] $2: expected '$3' got '$got'"; fail=1; fi
}

echo "=== live：cursor 两族各自解析 ==="
# [regress] 断言必须**版本无关**：钉死具体 id 会在 Cursor 上新版本当天变成假 FAIL。
# 真正要守的不变量只有三条：属于本族、是通用推理形态、落在高 effort 档。
LIVE=$(cursor-agent --list-models 2>/dev/null)
live_assert() { # <family> <ERE> <人话说明>
  got=$(printf '%s\n' "$LIVE" | pick_strongest "$1")
  printf "live %-7s -> %s\n" "$1" "${got:-<empty>}"
  if [ -z "$got" ]; then
    echo "FAIL live $1: 解析为空（未登录 / 列表取不到 / 该族命名已变，规则失配）"; fail=1
  elif ! printf '%s' "$got" | grep -qE "$2"; then
    echo "FAIL live $1: '$got' 不满足「$3」（$2）"; fail=1
  fi
}
live_assert gemini '^gemini-[0-9].*pro(-(x)?high)?$'    'gemini 族 + pro 线（非 flash）'
live_assert grok   '^cursor-grok-[0-9].*-(x)?high$'     'grok 族 + high/xhigh 档'

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
gpt-5.6-luna-high - X' | pick_strongest gpt high)
[ "$got" = "gpt-5.6-luna-high" ] && echo "PASS  extra-high 不被 /-high\$/ 误当 high 档" || { echo "FAIL  extra-high 混档: 实得 '$got'"; fail=1; }
got=$(printf '%s\n' "$BOTH" | pick_strongest gpt)
[ "$got" = "gpt-5.6-sol-xhigh" ] && echo "PASS  缺省仍 xhigh 优先（旧行为不变）" || { echo "FAIL  缺省档变了: 实得 '$got'"; fail=1; }
got=$(printf '%s\n' 'gpt-5.9-a-high - X
gpt-5.6-sol-xhigh - X' | pick_strongest gpt high)
[ "$got" = "gpt-5.9-a-high" ] && echo "PASS  版本仍优先于档位（high 偏好下）" || { echo "FAIL  版本优先破坏: 实得 '$got'"; fail=1; }

echo "=== gemini 族 ==="
assert gemini "[regress] 不被 -mini 规则误杀（ge-MINI 含 mini）" "gemini-3.1-pro" 'gemini-3.1-pro - X'
assert gemini "flash 版本更高也不得击败 pro（flash 是小模型）" "gemini-3.1-pro" 'gemini-3.5-flash - X
gemini-3.1-pro - X'
assert gemini "无 pro 的裸 id 不入选" "" 'gemini-4 - X'
assert gemini "pro 版本大者胜" "gemini-4.0-pro" 'gemini-3.1-pro - X
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

check() { # <name> <expect-substr> <actual>
  case "$3" in *"$2"*) echo "PASS  $1";; *) echo "FAIL  $1: 期望含 '$2'，实得: $3"; fail=1;; esac
}

echo "=== 运行时 0：gpt 族已退役 -> exit 64 并指路 codex；族参数必须显式给 ==="
make_stub ok
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o0.txt" gpt 2>&1); RC=$?
[ "$RC" = "64" ] && echo "PASS  gpt -> exit 64" || { echo "FAIL  gpt 应 exit 64，实得 $RC"; fail=1; }
check "gpt 报错指向 run-codex.sh" "run-codex.sh" "$OUT"
PATH="$STUB:$PATH" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o0b.txt" >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  缺族参数 -> exit 64（没有默认族）" || { echo "FAIL  缺族参数应 exit 64"; fail=1; }
PATH="$STUB:$PATH" bash "$SCRIPT" --resolve-only gpt >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  --resolve-only gpt -> exit 64" || { echo "FAIL  --resolve-only gpt 应 exit 64"; fail=1; }

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

echo "=== 运行时 3.5：幽灵 id fail-closed（gemini 的 fallback 就是它要保护的单点）==="
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
# 9a': gpt 族在 async 入口同样拒绝；族参数缺失拒绝
PATH="$STUB:$PATH" bash "$ASYNC" start "$WORK/p.txt" "$WORK/async-gpt.txt" gpt 60 >/dev/null 2>&1
[ "$?" = "64" ] && echo "PASS  async start gpt -> exit 64" || { echo "FAIL  async gpt 应 exit 64"; fail=1; }
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

rm -rf "$WORK"
exit $fail
