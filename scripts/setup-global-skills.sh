#!/usr/bin/env bash
# setup-global-skills.sh
# 把 AICAP SSOT 管理的 skills 链接到 ~/.claude/skills/，
# 让 Claude Code / Cursor / Codex 在任意项目里都能发现它们。
# 安全：只创建 symlink，不覆盖现有真实目录；可重复运行。

set -euo pipefail

AICAP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_SKILLS_SRC="$AICAP_ROOT/.claude/skills"
GLOBAL_DIR="$HOME/.claude/skills"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "  ${RED}✗${RESET} $*"; }

echo ""
echo "AICAP Global Skills Setup"
echo "  source : $CLAUDE_SKILLS_SRC"
echo "  target : $GLOBAL_DIR"
echo ""

# 检查 source 存在
if [[ ! -d "$CLAUDE_SKILLS_SRC" ]]; then
  err "找不到 $CLAUDE_SKILLS_SRC，请先在 AICAP 根目录运行 pnpm run ai:generate"
  exit 1
fi

# 创建全局目录（如不存在）
mkdir -p "$GLOBAL_DIR"

installed=0
skipped=0
warned=0

for skill_path in "$CLAUDE_SKILLS_SRC"/*/; do
  name="$(basename "$skill_path")"
  target="$GLOBAL_DIR/$name"

  if [[ -L "$target" ]]; then
    current="$(readlink "$target")"
    if [[ "$current" == "$skill_path" || "$current" == "${skill_path%/}" ]]; then
      ok "$name  (already linked, skip)"
      ((skipped++)) || true
    else
      warn "$name  → 指向不同路径 ($current)，跳过（手动检查）"
      ((warned++)) || true
    fi
  elif [[ -d "$target" ]]; then
    warn "$name  → 真实目录已存在，跳过（不覆盖）"
    ((warned++)) || true
  elif [[ -e "$target" ]]; then
    warn "$name  → 已存在但不是目录，跳过"
    ((warned++)) || true
  else
    ln -s "$skill_path" "$target"
    ok "$name  → linked"
    ((installed++)) || true
  fi
done

echo ""
echo "完成：新增 $installed 个 symlink，跳过 $skipped 个，需手动检查 $warned 个"
echo ""

if (( warned > 0 )); then
  echo -e "  ${YELLOW}有 $warned 个条目需要手动检查，运行 ls -la $GLOBAL_DIR 查看详情${RESET}"
  echo ""
fi

echo "验证（Claude Code / Cursor / Codex 均从此路径发现 skills）："
ls -1 "$GLOBAL_DIR"
echo ""
