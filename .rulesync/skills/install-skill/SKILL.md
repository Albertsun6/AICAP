---
name: install-skill
description: >-
  从任意 skill market（anthropics/skills、openai/skills、vercel-labs/agent-skills、cloudflare/skills 或自定义 org/repo）
  发现并安装新技能到 AICAP SSOT：市场发现（GitHub API 浏览/搜索，无副作用）→ 选源 → fetch → 展示新增列表 → 用户选择保留项 → 删除其余 → generate → symlink，一步到位。
  触发：安装 skill / 从市场安装 / install skill / install skill from market /
  拉取新 skill / 我想装个 skill / 查找并安装 skill / 浏览 skill 市场 / 看看有哪些 skill
targets: ["*"]
---

# install-skill

从任意远程 skill 源发现并拉取技能，选择性保留后纳入 AICAP SSOT。

## 常量

```
AICAP_ROOT = ~/Desktop/AICAP
SSOT_DIR   = $AICAP_ROOT/.rulesync/skills/
CLAUDE_DIR = $AICAP_ROOT/.claude/skills/
GLOBAL_DIR = ~/.claude/skills/
```

## 执行流程

### Step 0 — 市场发现（无副作用，纯读）

**入口判断**：
- 用户意图是"看看有什么"/"浏览"/"搜索" → 走完整 Step 0
- 用户已明确指定 skill 名或 org/repo → 跳过 Step 0，直接 Step 1

**0a — 选择要浏览的市场**

展示市场列表，允许多选：

```
支持的 skill 市场：

  [1] anthropics/skills        — Anthropic 官方，最高信任，纯 prompt，跨工具
  [2] openai/skills            — OpenAI 官方，Codex 生态
  [3] vercel-labs/agent-skills — Vercel 官方，React/Next/Vercel 栈
  [4] cloudflare/skills        — Cloudflare 平台专属
  [5] 自定义 org/repo           — 任意符合 SKILL.md 规范的仓库

请选择要浏览的市场（可多选，如 1 3，或 all）：
```

**0b — 用 GitHub API 拉取 skill 目录列表（不 fetch，无本地改动）**

对每个选中市场，尝试以下路径（按顺序，取第一个成功的）：

```bash
# 尝试 /skills 子目录
gh api /repos/<org>/<repo>/contents/skills --jq '[.[] | select(.type=="dir") | .name]' 2>/dev/null

# fallback：根目录下的目录
gh api /repos/<org>/<repo>/contents/ --jq '[.[] | select(.type=="dir") | .name]' 2>/dev/null
```

对每个 skill 目录，读取其 SKILL.md 的 description（只读远程，不写本地）：

```bash
gh api /repos/<org>/<repo>/contents/<skill-dir>/SKILL.md \
  --jq '.content' | base64 -d | head -30
```

记录已安装清单（与 `ls ~/.claude/skills/` 对比）。

**0c — 展示发现结果**

```
📦 anthropics/skills（共 N 个）     已安装 M 个

  [1] skill-creator       — Create new skills, modify and improve...     ✓ 已安装
  [2] webapp-testing      — Toolkit for interacting with local web...     ✓ 已安装
  [3] mcp-builder         — Scaffold and develop MCP servers...
  [4] frontend-design     — Design and build frontend UI components...
  [5] data-pipeline       — Build and orchestrate data pipelines...
  ...

操作提示：
  • 输入编号查看详情（如 "3"）
  • 输入 "install 3 5" 安装指定 skill
  • 输入 "search <关键词>" 在当前市场搜索
  • 输入 "switch" 切换/叠加另一个市场
  • 输入 "done" 退出不安装
```

**0d — 支持的交互操作**

| 输入 | 行为 |
|---|---|
| 单个编号（如 `3`） | 展示该 skill 的完整 description + 许可信息，返回列表 |
| `install 3 5` | 记录目标 slug 列表，进入 Step 1（source 已知，跳过 source 询问） |
| `install all` | 记录所有未安装的 skill，进入 Step 1 |
| `search <词>` | 对 description 做关键词过滤，重新展示匹配结果 |
| `switch` | 返回 0a 选择另一个市场（已选结果累积，不清空） |
| `done` / `exit` | 终止，不安装任何 skill |

Step 0 全程不写本地文件，只读 GitHub API。完成选择后携带 `{source, slugs}` 进入 Step 1。

### Step 1 — 确认源与目标

若来自 Step 0：source 和 slug 列表已确定，直接展示确认摘要，等用户确认后继续。

若直接进入（跳过 Step 0）：询问 skill 源（org/repo 或从市场列表选一个）和目标 slug。

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
