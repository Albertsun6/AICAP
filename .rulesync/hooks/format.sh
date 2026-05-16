#!/usr/bin/env bash
# postToolUse 格式化钩子（rulesync → 各工具的 hook 机制）
# 占位实现：按你团队真实 formatter 替换。保持幂等、快速、失败不阻断。
set -euo pipefail

# 示例：只有存在配置时才跑，避免在没装 formatter 的环境报错
if command -v pnpm >/dev/null 2>&1 && [ -f package.json ]; then
  pnpm exec prettier --write --ignore-unknown . >/dev/null 2>&1 || true
fi

exit 0
