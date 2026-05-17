---
name: install-skill
description: >-
  从 anthropics/skills 等主流 skill market 安装新技能到 AICAP SSOT：
  fetch → 展示新增列表 → 用户选择保留项 → 删除其余 → generate → symlink，一步到位。
  触发：安装 skill / 从 anthropics 安装 / install skill from market /
  拉取新 skill / 我想装个官方 skill
targets: ["*"]
---

# install-skill

从远程 skill 源（默认 anthropics/skills）拉取技能，选择性保留后纳入 AICAP SSOT。

## 常量

```
AICAP_ROOT = ~/Desktop/AICAP
SSOT_DIR   = $AICAP_ROOT/.rulesync/skills/
CLAUDE_DIR = $AICAP_ROOT/.claude/skills/
GLOBAL_DIR = ~/.claude/skills/
```

## 支持的 skill 源

| 源 | GitHub 路径 | 特点 |
|---|---|---|
| Anthropic 官方 | `anthropics/skills` | 最高信任，纯 prompt，跨工具 |
| OpenAI 官方 | `openai/skills` | Codex 生态官方 |
| Vercel 官方 | `vercel-labs/agent-skills` | React/Next/Vercel 栈 |
| Cloudflare | `cloudflare/skills` | CF 平台专属 |
| 自定义 | `<org>/<repo>` | 任意符合 SKILL.md 规范的仓库 |

## 执行流程

### Step 1 — 确认源与目标

询问用户（若触发时已给出则直接用）：

1. **skill 源**（默认 `anthropics/skills`，可输入任意 `org/repo`）
2. **想安装哪些 skill**（可以说"展示列表我来选"或直接给出 slug）

### Step 2 — 记录现有 skill 列表

```bash
ls ~/Desktop/AICAP/.rulesync/skills/
```

记下当前所有目录名，用于 Step 4 的对比。

### Step 3 — 执行 fetch

```bash
cd ~/Desktop/AICAP
GITHUB_TOKEN=$(gh auth token) npx rulesync fetch <source> --features skills
```

fetch 完成后列出 `.rulesync/skills/` 下**新增**的目录（与 Step 2 对比）。

### Step 4 — 展示新增清单，让用户选择

对每个新增目录，读取其 `SKILL.md` 的 `description` 字段，展示为表格：

```
新增的 skills（共 N 个）：

  [1] skill-creator    — Create new skills, modify and improve existing skills...
  [2] webapp-testing   — Toolkit for interacting with and testing local web apps...
  [3] mcp-builder      — Scaffold and develop MCP servers...
  ...

请输入要保留的编号（如 1 2，或 all，或 none）：
```

等待用户输入后继续。

### Step 5 — 删除不保留的 skill

对用户未选择的所有新增目录：

```bash
rm -rf ~/Desktop/AICAP/.rulesync/skills/<unwanted-name>
```

在删除前列出将要删除的列表，让用户最终确认（一行确认即可，不要过度询问）。

### Step 6 — 生成三工具产物

```bash
cd ~/Desktop/AICAP && pnpm run ai:generate
```

检查输出中是否包含所有保留 skill 的写入行。若报错展示错误并停止。

### Step 7 — 创建全局 symlink

对每个保留的新 skill：

```bash
ln -s ~/Desktop/AICAP/.claude/skills/<name> ~/.claude/skills/<name>
```

若已存在同名 symlink，跳过并提示（不静默覆盖）。

### Step 8 — 汇报

```bash
ls -la ~/.claude/skills/
```

输出安装结果摘要：

```
✓ 安装完成

  已安装（N 个）：
    skill-creator  → ~/Desktop/AICAP/.claude/skills/skill-creator
    webapp-testing → ~/Desktop/AICAP/.claude/skills/webapp-testing

  已跳过（M 个）：mcp-builder, frontend-design, ...

  工具覆盖：Claude Code / Cursor / Codex / Copilot
```

## 约束与注意

- **许可审查**：安装前检查 SKILL.md frontmatter 是否有 `license` 字段；document-skills 类为 source-available（非 OSS），纳入 SSOT 再分发前需提示用户确认
- **可移植性**：若 SKILL.md 使用了 `context: fork` / `allowed-tools` / Claude 专有 hook，提示用户该 skill 在 Cursor/Codex 下会退化，由用户决定是否继续
- **不批量安装**：不要在没有用户选择的情况下保留全部 fetch 结果；未选择的全部删除
- **GitHub 认证**：若 `gh auth token` 失败，提示用户先运行 `gh auth login`
