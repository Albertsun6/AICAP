# Skills 说明文档

全局发现路径：`~/.claude/skills/`（Claude Code / Cursor / Codex 均读）。
SSOT 管理路径：`AICAP/.rulesync/skills/` → `pnpm run ai:generate` → `AICAP/.claude/skills/` → symlink。

---

## SSOT 管理的 Skills（9 个，跨工具同步）

### `/survey`
**用途**：对任意话题做系统性调研——选型比较、最佳实践、社区方案研究。

流程：Phase 1 问题界定 → 1.5 Brief → Phase 2（2 Claude + 1 cursor-agent 并行异构搜索）→ 2.5 Reflection Gate → 3-5 综合报告 → 5.5 Citation Health → Phase 6 异构终审 + 最多 3 轮辩论 → Finalize（`.md` 报告 + `.m4a` 音频）。

触发：`/survey X` / "调研X方案" / "比较X和Y" / "X的最佳实践"

> 无 flag。每个阶段都是质量门禁，不可跳过。cursor-agent 不可用时自动降级并 banner 提示。

---

### `/debate-review`
**用途**：收到外部 AI 的评审反馈后，逐条结构化裁决——接受 / 部分接受 / 反驳，形成判断矩阵并把改动落到原文件。

适用：架构 plan 评审、PR review、设计 spec 批注。

触发：粘贴一份 AI 评审内容 + "帮我裁决" / "debate this"

> 仅负责 phase 3 裁决。输入需要 4 份 phase 1/2 文件，缺失则拒绝执行。

---

### `/report-to-html`
**用途**：把长 Markdown 报告（200+ 行，含表格/流程图/引用链接）转成单文件交互式 HTML——粘性目录、Mermaid 图、Accordion、Pill 状态徽章、打印友好。零构建，双击即开。

适用：调研报告、架构文档、方案对比。不适用：多文档站、PPT、需要后端的应用。

触发：`/report-to-html xxx.md` / "把这个报告转成 HTML" / "做成交互式网页"

---

### `/conventional-commit`
**用途**：基于实际 `git diff` 生成规范的 Conventional Commits 提交信息。只输出建议，不自动执行 `git commit`（除非明确要求）。

格式：`<type>(<scope>): <摘要>` + body（why）+ footer（BREAKING CHANGE / Closes #）

触发："写提交信息" / "commit 这个" / "生成 commit message"

---

### `/project-context`
**用途**：快速输出当前项目的目标、架构概览、关键约束、共享约定、验证方式，供新任务或跨模块改动时拉齐上下文。约 300 字，信息来源优先仓库内文档，推断部分明确标注。

触发："介绍一下这个项目" / "会话开始帮我了解项目" / 新接手任务时

---

### `/skill-creator`
**用途**：创建新 skill、修改/优化现有 skill、运行 eval 测量 skill 性能。提供标准化的 skill 草稿 → 测试 → 定量评估 → 迭代改进流程。

适用：AICAP SSOT 自身维护——新增 skill 或改进现有 skill 的触发准确度。

触发："创建一个新 skill" / "优化这个 skill 的描述" / "跑 eval 测一下"

---

### `/webapp-testing`
**用途**：用 Playwright 测试本地 Web 应用——验证前端功能、调试 UI 行为、截图、查看浏览器 console 日志。提供 `scripts/with_server.py` 管理服务器生命周期。

触发："测一下这个网页功能" / "帮我验证前端" / "截图看看现在 UI 状态"

---

### `/install-skill`
**用途**：从 anthropics/skills 等主流 skill market 安装新技能到 AICAP SSOT——fetch → 展示新增列表 → 用户选择保留 → 删除其余 → generate → symlink，全程引导。

触发："从 anthropics 安装 skill" / "install skill from market" / "拉取新 skill"

---

### `/aicap-commit`
**用途**：AICAP 专用提交流程——检测 `.rulesync/skills/` 变动 → 更新 SKILLS.md → 重新生成 SKILLS.html / README.html → `pnpm run ai:generate` → 规范提交。

触发：`/aicap-commit` / "提交到 AICAP" / "帮我提交这次改动"（在 AICAP 目录内）

---

## 本地专用 Skills（3 个，非 SSOT，仅本机）

> 这 3 个 skill 直接存放在 `~/.claude/skills/`，不经 rulesync 同步，Seaidea 项目专属。

### `/feature-fullstack`
**用途**：端到端实施一个 Seaidea/claude-web feature，覆盖 backend + iOS + 验证 + 真机部署，一次完成。从 M0.5 实施经验蒸馏（~1100 行新代码，4 个 feature，一次 sitting 验证到位）。

触发："全做" / "ship 这个功能" / "实施 M0.X" / "feature 全栈" / "测完装手机"

---

### `/ios-e2e-test`
**用途**：全自动 Seaidea iOS app 端到端测试——验证 backend 健康、启动模拟器、WebSocket 探针确认完整通知链（backend → ServerChan），截图存档，测试通过后可选真机部署。

触发："在模拟器跑 iOS 测试" / "验证 iOS 端到端" / "跑 e2e 测试" / "装到手机"

---

### `/fedex-tracker`
**用途**：批量查询 FedEx 追踪号的发货日期，输出 CSV。用真实 Chrome（CDP 驱动）模拟点击绕过 Akamai 反爬，随机延迟 8-15s。

触发：有一批 FedEx 追踪号需要提取发货日期时

---

## 维护规则

**新增 SSOT skill 的标准流程**：
```bash
# 1. 在 SSOT 源里创建 skill
mkdir AICAP/.rulesync/skills/<name> && vim AICAP/.rulesync/skills/<name>/SKILL.md

# 2. 生成三工具产物
cd AICAP && pnpm run ai:generate

# 3. 创建全局 symlink
ln -s /Users/yongqian/Desktop/AICAP/.claude/skills/<name> ~/.claude/skills/<name>
```

不要直接在 `~/.claude/skills/` 建真实目录，除非明确只用于本地单机且不打算跨工具同步。
