#!/usr/bin/env bash
# /survey — run-codex.sh 与 lib/agent-common.sh 的可执行断言
#
# 为什么要有这个文件：codex 通道的契约（exit code / 认证实打 / 进程树屠杀 / 段落校验）
# 都是 2026-09-09 实测钉出来的；codex CLI 升级或 lib 被改动时，先跑这个再谈别的。
# 默认只跑**零配额**用例；带 SURVEY_TEST_LIVE_CALL=1 才真调一次模型（effort=low，tiny prompt）。
#
# 跑：bash test-run-codex.sh   （全绿 exit 0；--resolve-only / --auth-check 两条需要已登录的 codex）

set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/run-codex.sh"
LIB="$DIR/lib/agent-common.sh"
fail=0

check() { # <name> <expect-substr> <actual>
  case "$3" in *"$2"*) echo "PASS  $1";; *) echo "FAIL  $1: 期望含 '$2'，实得: $(printf '%s' "$3" | head -3)"; fail=1;; esac
}
expect_rc() { # <name> <expected-rc> <actual-rc>
  if [ "$3" = "$2" ]; then echo "PASS  $1 -> exit $3"; else echo "FAIL  $1: 期望 exit $2 实得 $3"; fail=1; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/survey-test-codex.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
echo "Reply with exactly: HELLO" > "$WORK/p.txt"

echo "=== 1. 参数契约（零配额）==="
bash "$SCRIPT" >/dev/null 2>&1;                                    expect_rc "无参数" 64 $?
bash "$SCRIPT" "$WORK/p.txt" "$WORK/o.txt" gemini >/dev/null 2>&1;  expect_rc "非 codex lens" 64 $?
bash "$SCRIPT" --auth-check extra >/dev/null 2>&1;                 expect_rc "--auth-check 多余参数" 64 $?
bash "$SCRIPT" --resolve-only codex extra >/dev/null 2>&1;         expect_rc "--resolve-only 多余参数" 64 $?
bash "$SCRIPT" "$WORK/missing.txt" "$WORK/o.txt" >/dev/null 2>&1;   expect_rc "prompt 文件缺失" 66 $?

echo "=== 2. 未安装 -> 69（PATH 里没有 codex）==="
mkdir -p "$WORK/emptybin"
OUT=$(PATH="$WORK/emptybin:/usr/bin:/bin" bash "$SCRIPT" "$WORK/p.txt" "$WORK/o.txt" 2>&1); RC=$?
expect_rc "codex 不在 PATH" 69 "$RC"
check "未安装给出安装指引" "npm i -g @openai/codex" "$OUT"

echo "=== 3. lib 版本护栏 ==="
OUT=$(AGENT_COMMON_REQUIRE=99 bash -c ". '$LIB'" 2>&1); RC=$?
expect_rc "lib 版本不匹配 fail-loud" 64 "$RC"
check "护栏文案指出版本不匹配" "版本不匹配" "$OUT"
OUT=$(bash -c ". '$LIB'" 2>&1); RC=$?
expect_rc "未声明 AGENT_COMMON_REQUIRE 也拒绝" 64 "$RC"

echo "=== 4. assert_sections / check_required_sections ==="
printf '## Compressed Findings\nx\n## Source Inventory\ny\n' > "$WORK/good.md"
printf '## Compressed Findings\nx\n' > "$WORK/bad.md"
AGENT_COMMON_REQUIRE=1 bash -c ". '$LIB'; assert_sections '$WORK/good.md' '## Compressed Findings' '## Source Inventory'" 2>/dev/null
expect_rc "两段齐全 -> 0" 0 $?
OUT=$(AGENT_COMMON_REQUIRE=1 bash -c ". '$LIB'; assert_sections '$WORK/bad.md' '## Compressed Findings' '## Source Inventory'" 2>&1); RC=$?
expect_rc "缺段 -> 非 0" 1 "$RC"
check "缺段报出完整段名（含空格，不被 IFS 切碎）" "- ## Source Inventory" "$OUT"
# `|` 分隔 + 段名带空格：这是实测踩过的坑（按空格分词会去找一个不存在的段名 "Section"）
AGENT_COMMON_REQUIRE=1 SURVEY_REQUIRE_SECTIONS='## Compressed Findings|## Source Inventory' \
  bash -c ". '$LIB'; check_required_sections '$WORK/good.md'" 2>/dev/null
expect_rc "SURVEY_REQUIRE_SECTIONS 用 | 分隔生效" 0 $?
AGENT_COMMON_REQUIRE=1 SURVEY_REQUIRE_SECTIONS='## Compressed Findings|## Nonexistent Section' \
  bash -c ". '$LIB'; check_required_sections '$WORK/good.md'" 2>/dev/null
expect_rc "缺 '## Nonexistent Section' -> 非 0" 1 $?
AGENT_COMMON_REQUIRE=1 bash -c ". '$LIB'; check_required_sections '$WORK/bad.md'" 2>/dev/null
expect_rc "未设置 SURVEY_REQUIRE_SECTIONS -> 不校验，0" 0 $?

echo "=== 5. watchdog：自立进程组的孙进程也必须被杀（codex-code-mode-host 模式）==="
MARK="survey-kill-test-$$"
T0=$(date +%s)
AGENT_COMMON_REQUIRE=1 bash -c ". '$LIB'
run_with_deadline 3 '$WORK/wd.out' '$WORK/wd.err' -- bash -c 'python3 -c \"import os,time; os.setpgrp(); time.sleep(120)  # $MARK\" & sleep 120'"
RC=$?
EL=$(( $(date +%s) - T0 ))
expect_rc "挂死命令被 watchdog 杀掉" 124 "$RC"
sleep 1
LEFT=$(pgrep -f "$MARK" 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEFT" = "0" ]; then echo "PASS  setpgrp 孙进程无泄漏"; else echo "FAIL  泄漏 $LEFT 个 setpgrp 孙进程（纯进程组屠杀会漏它）"; pkill -f "$MARK" 2>/dev/null; fail=1; fi
[ "$EL" -le 12 ] && echo "PASS  watchdog 及时触发（${EL}s）" || { echo "FAIL  watchdog 过慢: ${EL}s"; fail=1; }

echo "=== 6. --auth-check 在无凭据环境下 -> 67（不许把'没 token'洗成通过）==="
mkdir -p "$WORK/nohome"
OUT=$(CODEX_HOME="$WORK/nohome" bash "$SCRIPT" --auth-check 2>&1); RC=$?
expect_rc "空 CODEX_HOME" 67 "$RC"
check "指出 auth.json 缺失" "no auth.json" "$OUT"

echo "=== 7. 额度留痕读写（lib）==="
AGENT_COMMON_REQUIRE=1 SURVEY_STATE_DIR="$WORK/state" bash -c ". '$LIB'; record_quota_block codex 'You have hit your usage limit. Resets at 2099-01-01'"
check "留痕含 lens 名" "codex" "$(cat "$WORK/state/quota-state" 2>/dev/null)"
AGENT_COMMON_REQUIRE=1 SURVEY_STATE_DIR="$WORK/state" bash -c ". '$LIB'; clear_quota_block codex"
[ -s "$WORK/state/quota-state" ] && { echo "FAIL  clear 后留痕仍在"; fail=1; } || echo "PASS  clear 清掉了留痕"

if command -v codex >/dev/null 2>&1; then
  echo "=== 8. live：--resolve-only（零配额，读本地目录）==="
  OUT=$(bash "$SCRIPT" --resolve-only 2>"$WORK/ro.err"); RC=$?
  expect_rc "resolve-only" 0 "$RC"
  case "$OUT" in gpt-*) echo "PASS  解析出 gpt 系 id: $OUT";; *) echo "FAIL  解析结果不像 gpt id: '$OUT'"; fail=1;; esac
  check "stderr 打 MODEL: 行（含 src=）" "src=" "$(cat "$WORK/ro.err")"
  check "stderr 明说认证未验证（doctor 不得据此报绿）" "AUTH: unverified" "$(cat "$WORK/ro.err")"
  OUT=$(SURVEY_CODEX_MODEL='definitely-not-a-real-model-xyz' bash "$SCRIPT" --resolve-only 2>"$WORK/ro2.err")
  check "钉了目录里没有的 id -> 标 unlisted" "unlisted" "$(cat "$WORK/ro2.err")"
  OUT=$(SURVEY_CODEX_MODEL='definitely-not-a-real-model-xyz' bash "$SCRIPT" "$WORK/p.txt" "$WORK/o-unl.txt" 2>&1); RC=$?
  expect_rc "run 模式对 unlisted 钉值 fail-closed（不烧调用）" 65 "$RC"

  echo "=== 9. live：--auth-check（零配额实打服务端）==="
  OUT=$(bash "$SCRIPT" --auth-check 2>&1); RC=$?
  case "$RC" in
    0)  echo "PASS  auth-check 通过";;
    67) echo "WARN  auth-check 报凭据失效（若你确实没登录这是对的；否则请查）";;
    *)  echo "FAIL  auth-check exit $RC: $OUT"; fail=1;;
  esac

  if [ "${SURVEY_TEST_LIVE_CALL:-0}" = "1" ]; then
    echo "=== 10. live：真调用一次（effort=low，消耗少量额度）==="
    printf 'Output EXACTLY two markdown sections titled "## Compressed Findings" and "## Source Inventory". Under the first write one bullet: the current year. Under the second write one bullet: https://example.com\n' > "$WORK/live.txt"
    OUT=$(SURVEY_CODEX_EFFORT=low SURVEY_REQUIRE_SECTIONS='## Compressed Findings|## Source Inventory' \
          bash "$SCRIPT" "$WORK/live.txt" "$WORK/live-out.md" 2>&1); RC=$?
    expect_rc "真调用 + 段落校验" 0 "$RC"
    check "OK 行含模型与档位" "effort=low" "$OUT"
    OUT=$(SURVEY_CODEX_EFFORT=low SURVEY_REQUIRE_SECTIONS='## Compressed Findings|## Absolutely Missing' \
          bash "$SCRIPT" "$WORK/live.txt" "$WORK/live-out2.md" 2>&1); RC=$?
    expect_rc "缺约定段 -> 66" 66 "$RC"
  else
    echo "（跳过 10. 真调用：设 SURVEY_TEST_LIVE_CALL=1 才跑，避免无谓消耗订阅额度）"
  fi
else
  echo "（codex 未安装，跳过 live 用例 8-10）"
fi

exit $fail
