---
name: sync-aicap
description: 同步 AICAP skills 到最新版本：git pull → 检测变动 → pnpm run ai:generate → pnpm run setup:skills → 展示新增/删除/更新的 skill 列表。 若本地有未推送的新 skill，还可更新文档并开 PR 推给团队。 触发：同步 AICAP / sync aicap / 更新 AICAP / 拉取最新 skills / AICAP 有更新 / update aicap skills / 把本地 skill 提交 PR
---
# sync-aicap

双向同步：从远端拉最新 AICAP skills，或把本地新 skill 推给团队（PR）。

## 常量

```
AICAP_ROOT = ~/Desktop/AICAP   （如迁移路径，在此更新）
```

## 模式判断

进入时先检查工作区状态，决定走哪条路：

```bash
cd ~/Desktop/AICAP
git status --short
git log origin/main..HEAD --oneline   # 有无本地未推送提交
```

| 情况 | 走哪条路 |
|---|---|
| 无本地改动、无未推提交 | **模式 A：拉取同步**（拉远端最新） |
| 有本地新 skill（`.rulesync/skills/` 下有新目录）| **模式 B：推送 PR**（更新文档 + 开 PR） |
| 两者都有 | 询问用户：先拉再推，还是只推 |

---

## 模式 A：拉取同步（从远端更新本机）

### A1 — 记录当前 skill 快照

```bash
ls ~/Desktop/AICAP/.rulesync/skills/
```

保存为 `BEFORE` 列表。

### A2 — git pull

```bash
cd ~/Desktop/AICAP && git pull
```

- 若已是最新（`Already up to date.`），告知用户，**仍继续执行 A3-A4**（幂等保证）。
- 若有 merge conflict，**停止**，报告冲突文件，提示手动解决后重试。

### A3 — 重新生成工具产物

```bash
cd ~/Desktop/AICAP && pnpm run ai:generate
```

### A4 — 更新全局 symlink

```bash
cd ~/Desktop/AICAP && pnpm run setup:skills
```

### A5 — 展示变动 diff

对比 `BEFORE` 与当前 `ls .rulesync/skills/`：

```
✅ 同步完成

新增 (2):
  + webapp-testing   — 用 Playwright 测试本地 Web 应用
  + install-skill    — 从主流 market 安装新 skill 到 AICAP SSOT

更新 (1):
  ~ survey           — description 更新

删除 (0): 无

本机全局路径 ~/.claude/skills/ 已同步，共 10 个 skill。
```

Claude Code / Cursor 通常热加载 skills，无需重启；若未生效建议重启工具。

---

## 模式 B：推送 PR（把本地新 skill 推给团队）

适用：用户在本地新增了 skill（`.rulesync/skills/<name>/SKILL.md` 存在但未提交或未推送），想贡献给团队。

### B1 — 确认新增的 skill

列出 `git status` 中 `.rulesync/skills/` 下的新目录，逐一展示 description，让用户确认要推送哪些。

### B2 — 更新文档

按 `aicap-commit` skill 的 Step 3-5 逻辑：
1. 更新 `SKILLS.md`：新增对应条目，skill 总数 +N
2. 重新生成 `SKILLS.html`（调用 `report-to-html` 逻辑）
3. 重新生成 `README.html`

### B3 — 重新生成工具产物

```bash
cd ~/Desktop/AICAP && pnpm run ai:generate
```

### B4 — 暂存并提交

```bash
git add \
  SKILLS.md SKILLS.html README.html \
  .rulesync/skills/<new-skill>/ \
  .claude/skills/<new-skill>/ .cursor/skills/<new-skill>/ \
  .codex/skills/<new-skill>/ .github/skills/<new-skill>/
```

按 Conventional Commits 生成提交信息：`feat(skills): add <name> skill`，body 列出 skill 用途。

### B5 — 创建 feature branch 并开 PR

```bash
# 用 skill 名作为分支名
git checkout -b skill/<new-skill-name>
git push -u origin skill/<new-skill-name>
gh pr create \
  --title "feat(skills): add <name>" \
  --body "..." \
  --base main
```

PR body 自动填入：
- skill 的 description
- 触发词列表
- targets（支持哪些工具）
- 测试方式（如何验证 skill 可触发）

### B6 — 汇报 PR 链接

输出 PR URL，提示团队成员 review 后合并即可。

---

## 约束

- **模式 A 不自动 push**——只拉取，不推送
- **模式 B 在 feature branch 开 PR，不直接推 main**
- **不修改 `.rulesync/` 规则文件**——只处理 skills 目录
- **conflict 不自动解决**——遇到 merge conflict 立即停止，提示人工介入
- **幂等**——无论运行几次，结果一致
