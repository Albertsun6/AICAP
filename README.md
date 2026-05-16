# ai-capabilities — 跨 AI 编码工具能力的单一事实来源（SSOT）

团队所有 AI 编码工具（Claude Code / Cursor / Codex / Copilot）的项目级指令、技能、子代理、命令、MCP，
**只在 `.rulesync/` 里定义一次**，用 [`rulesync`](https://github.com/dyoshikawa/rulesync) 生成到各工具各自的目录/文件名。

> 设计依据见同目录上层的调研报告《跨AI编码工具能力体系化管理-完整报告》。本仓库是该报告"落地最小 7 步"的骨架实现。

## 心智模型

```
.rulesync/  (SSOT，唯一手写处)
  ├── rules/         AGENTS.md / CLAUDE.md 内容（root + 路径作用域分层）
  ├── skills/        可复用能力包 SKILL.md（流程性 know-how）
  ├── subagents/     子代理定义
  ├── commands/      slash command
  ├── mcp.json       MCP server 清单（只写 env 占位，不写密钥）
  └── hooks.json     生命周期钩子
        │
        │  rulesync generate   ← 适配生成层
        ▼
  CLAUDE.md + .claude/   (Claude Code 读 CLAUDE.md)
  AGENTS.md + .codex/    (Codex 读 AGENTS.md)
  AGENTS.md + .cursor/   (Cursor 读 AGENTS.md / .cursor/rules/*.mdc)
  .github/…              (Copilot)
```

分层定位：`rules = 配置/约定(WHAT/WHERE)` · `skills = 流程能力(HOW)` · `mcp = 工具访问(TOOLS)`，三者正交不混。

## 铁律

1. **只改 `.rulesync/`**。`CLAUDE.md` / `AGENTS.md` / `.cursor/` / `.claude/` / `.codex/` / `.github/` 全是**生成产物**——手改会被 CI drift gate 拦截，也会被下次 `generate` 覆盖。
2. **生成产物随源一起提交**（已特意不 gitignore 它们）。CI 靠"重新生成后 `git diff` 为空"判断无漂移。
3. **保持 SSOT 小且手写**。根规则 `.rulesync/rules/overview.md` 控制在 ~200 行内；领域专属约定拆成路径作用域的小文件（见 `rules/testing.md` 示例）。不要让 LLM 自动灌大段配置。
4. **密钥不入库**。`mcp.json` 只写 `${ENV_VAR}` 占位；真实密钥放各人 shell 环境 / user-scope 配置。

## 日常工作流

```bash
pnpm install                 # 安装 pin 住的 rulesync@8.18.0
# 改 .rulesync/ 下的源文件 …
pnpm run ai:generate         # 重新生成各工具产物
pnpm run ai:check            # = generate + git diff --exit-code，本地预演 CI drift gate
git add -A && git commit     # 源 + 生成产物一起提交
```

新成员 onboard：`git clone` → `pnpm install` → `pnpm run ai:generate` → 各工具即拥有全套团队能力。

## 治理

| 机制 | 实现 |
|---|---|
| 评审 | PR 只评审 `.rulesync/`；生成产物 diff 仅用于核对 |
| 漂移门禁 | `.github/workflows/ai-config-drift.yml`：CI 重生成 + `git diff --exit-code` |
| 质量回归 | `promptfoo/promptfooconfig.yaml`：高价值 skill 的 golden-trace 回归（按需在 workflow 里启用 `prompt-eval`） |
| 命名/小文件 | kebab-case；单文件单职责；根规则行数上限（建议加 lint/pre-commit 强制） |
| 权限边界 | secrets 走 env 占位；Claude 侧可在 `.rulesync/` 经 hooks/settings 下发 `permissions.deny` 等组织级硬约束 |
| 版本 pin | `package.json` 与 CI 均 pin `rulesync@8.18.0`，升级走 PR 并复核 diff |

## 目标工具

`rulesync.jsonc` 的 `targets` 控制生成哪些工具，当前：`copilot, cursor, claudecode, codexcli`。
增删工具改这里再 `generate`。完整支持列表见 rulesync 文档。

## 风险与逃生口

- rulesync 是社区项目（单一主 maintainer，MIT）。已 pin 版本；每季度复审 maintainer/release/license。
- 极端情况可弃用工具、退回纯约定：把 `.rulesync/rules/overview.md` 内容直接作为 `AGENTS.md`，并在 `CLAUDE.md` 写 `@AGENTS.md` import（Claude Code 不原生读 AGENTS.md，只读 CLAUDE.md）。
- MCP 官方 Registry 仍处 preview，可能 breaking change——不要在关键路径硬依赖其稳定性。
- `rulesync` 对 Claude Code 的 MCP 输出以实际 `generate` 结果为准（本骨架已验证生成 `.mcp.json`）。

## 这个骨架已验证

`rulesync@8.18.0 init → 填充 SSOT → generate` 跑通，Claude Code(`CLAUDE.md`)、Codex/Cursor(`AGENTS.md`)、
Cursor(`.cursor/rules/*.mdc`)、`.mcp.json` 均正确生成；`pnpm run ai:check` 幂等（无漂移）。
`.rulesync/` 内 `rules/overview.md`、`rules/testing.md`、`skills/project-context`、`skills/conventional-commit`、
`subagents/planner.md`、`commands/review-pr.md`、`mcp.json`、`hooks.json` 均为可直接替换的真实模板。
