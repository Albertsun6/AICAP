---
name: aicap-commit
description: >-
  AICAP 专用提交流程：检测 .rulesync/skills/ 变动 → 更新 SKILLS.md →
  重新生成 SKILLS.html / README.html → pnpm run ai:generate → 规范提交。
  触发：提交到 AICAP / aicap commit / commit aicap changes /
  我要提交 AICAP / 帮我提交这次改动（在 AICAP 项目目录内）
targets: ["*"]
---

# aicap-commit

AICAP 仓库的专用提交 workflow，在 `conventional-commit` 基础上补充四个自动步骤：
更新 SKILLS.md → 生成 SKILLS.html → 生成 README.html → `pnpm run ai:generate`。

## 常量

```
AICAP_ROOT = ~/Desktop/AICAP   （如迁移路径，在此更新）
```

## 执行流程

### Step 1 — 检查工作区状态

```bash
git diff --stat HEAD
git status --short
```

确认有实际改动后继续。若工作区干净，提示用户并停止。

### Step 2 — 若 `.rulesync/` 有变动，重新生成工具产物

```bash
# 检查 .rulesync/ 是否有改动
git diff --name-only HEAD | grep -q "^\.rulesync/"
# 或检查未暂存/未追踪文件
git status --short | grep -q "\.rulesync/"
```

若命中，执行：

```bash
cd ~/Desktop/AICAP && pnpm run ai:generate
```

检查输出无报错后继续。

### Step 3 — 若 skills 有变动，更新 SKILLS.md

检查条件（任一满足即更新）：
- `.rulesync/skills/` 下有新增/删除/重命名目录
- 已有 skill 的 `SKILL.md` description 字段有变化

更新内容：
1. 重新统计 skill 总数（`ls .rulesync/skills/ | wc -l`）
2. 对每个 skill 读取 `.rulesync/skills/<name>/SKILL.md` 的 `description` 字段
3. 更新 `SKILLS.md` 中对应 skill 的描述段（保持格式，只改内容）
4. 更新顶部总览表的行数和技能描述

**不要重写整个 SKILLS.md**——只改有变化的条目。如果改动太大（如新增 skill），用 Write 工具重写完整文件。

### Step 4 — 生成 SKILLS.html

调用 `/report-to-html` 的逻辑（不重复触发 skill，直接按其规范生成）：

- 读取更新后的 `SKILLS.md`
- 输出 `SKILLS.html`（覆盖旧版）
- 保持与现有 SKILLS.html 相同的结构：侧栏目录 + skill 卡片 + Mermaid SSOT 流程图

### Step 5 — 生成 README.html

读取 `README.md`，生成 `README.html`，放在同目录。

README.html 结构（与 SKILLS.html 统一风格）：
- 顶部 sticky bar：标题 + "AICAP SSOT" pill + 打印按钮
- 左侧粘性目录（提取 README 的 ## 章节）
- Hero 卡：一句话说明 + 关键 pill（当前 skill 数 / rulesync 版本）
- 安装指南章节突出显示（左边框 + 代码块）
- 其余章节按 section-card 排列
- 零构建，Tailwind + Alpine + Mermaid CDN

### Step 6 — 暂存所有生成产物

```bash
git add \
  SKILLS.md SKILLS.html README.html \
  .rulesync/skills/ \
  .claude/skills/ .cursor/skills/ .codex/skills/ .github/skills/ \
  package.json
```

连同用户原本要提交的文件一起暂存。

### Step 7 — 生成提交信息并提交

按 Conventional Commits 规范生成提交信息：

- `feat(skills):` — 新增 skill
- `fix(skills):` / `refactor(skills):` — 修改已有 skill
- `docs:` — 只改文档/README
- `chore(aicap):` — 工具配置变动

Scope 可叠加，如 `feat(skills)!:` 表示 breaking change。

body 里列出：
- 新增/修改的 skill 名
- SKILLS.md / README 是否更新
- 是否重新 generate

执行提交（不自动 push，除非用户明确要求）：

```bash
git commit -m "..."
```

### Step 8 — 汇报 + 询问是否 push

输出一行摘要：已提交文件数、commit hash 前 7 位。
然后询问："要推送到远端吗？`git push`"

若用户确认，执行 `git push`。

## 约束

- **不改 `.rulesync/rules/` 内容**——只读，不写（规则变更必须由人工触发）
- **不自动 push**——提交后必须询问用户
- **SKILLS.md 和 README 更新要保守**——只改有变化的部分，不做无谓的格式重排
- **README.html 每次提交都重新生成**——确保与最新 README.md 同步
