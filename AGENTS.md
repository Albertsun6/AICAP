Please also reference the following rules as needed. The list below is provided in TOON format, and `@` stands for the project root directory.

rules[1]:
  - path: @.codex/memories/testing.md
    description: 测试约定（路径作用域示例：仅在改测试文件时加载，演示分层规则）
    applyTo[4]: **/*.test.*,**/*.spec.*,**/__tests__/**,tests/**

# 项目总则（SSOT 根规则）

> 这是**单一事实来源**。所有工具（Claude Code / Cursor / Codex / Copilot）的项目级指令都从这里生成，
> **不要直接改生成出来的 CLAUDE.md / AGENTS.md / .cursor/rules——改这里，然后 `rulesync generate`**。
> 原则：手写、分层、保持小。本文件超过 ~200 行就拆到 `.rulesync/rules/<topic>.md`（路径作用域）。

## 项目约定（按你团队真实情况替换以下占位）

- 主语言 / 框架：`<填写，如 TypeScript + Node 22>`
- 包管理器：`<填写，如 pnpm>`，提交前必须 `<lint 命令>` 与 `<test 命令>` 通过
- 目录约定：按 feature 组织，不按文件类型；相关文件就近放置
- 命名：kebab-case 文件名；公共标识符语义化、可验证

## 工作方式（对所有 AI 工具生效）

- 改动前先读相关文件与本规则；不臆造不存在的 API / 文件
- 小步提交，每个改动可独立回滚；不在一个提交里混多个无关变更
- 不确定时先问，不要静默做出影响范围大的决定
- 不把 secrets 写进任何被提交的文件；密钥走 user-scope MCP 配置或环境变量

## 这套体系怎么用（贡献者必读）

1. 改能力 = 改 `.rulesync/` 下的源文件（rules / skills / subagents / commands / mcp）
2. 跑 `pnpm run ai:generate`（= `rulesync generate --targets "*" --features "*"`）
3. 把**源文件 + 生成产物一起提交**（生成物纳入版本控制，CI drift gate 才能比对）
4. PR 只评审 `.rulesync/` 源；生成物视为构建产物，diff 仅用于核对
