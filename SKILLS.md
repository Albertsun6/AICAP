# Skills 说明文档

全局发现路径：`~/.claude/skills/`（Claude Code / Cursor / Codex 均读）。
SSOT 管理路径：`AICAP/.rulesync/skills/` → `pnpm run ai:generate` → `AICAP/.claude/skills/` → symlink。

---

## SSOT 管理的 Skills（20 个，跨工具同步）

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
**用途**：从任意 skill market（anthropics/skills、openai/skills、vercel-labs/agent-skills、cloudflare/skills 或自定义 org/repo）发现并安装新技能到 AICAP SSOT。先用 GitHub API 无副作用地浏览市场、搜索关键词、查看详情，选好后再 fetch → 保留选中项 → generate → symlink，全程引导。

触发："安装 skill" / "从市场安装" / "浏览 skill 市场" / "看看有哪些 skill" / "install skill from market"

---

### `/find-skills`
**用途**：在对话中即时发现并安装 agent skill。当用户问 "how do I do X" / "有没有能做 X 的 skill" / "find a skill for X" 时自动激活，内部通过 Skills CLI（`npx skills find` / `npx skills add`）从开放 skill 生态搜索并安装。

与 `/install-skill` 互补：`find-skills` 偏对话内即时发现，`install-skill` 偏团队级 SSOT 固化（GitHub API → 选源 → generate → symlink，纳入版本控制）。

> 来源：vercel-labs/skills `skills/find-skills`。纯 prompt，无 license/hook 约束，跨工具完全可移植。

触发："find a skill for X" / "有没有能做 X 的 skill" / "how do I do X"（X 可能存在现成 skill 时）

---

### `/aicap-commit`
**用途**：AICAP 专用提交流程——检测 `.rulesync/skills/` 变动 → 更新 SKILLS.md → 重新生成 SKILLS.html / README.html → `pnpm run ai:generate` → 规范提交。

触发：`/aicap-commit` / "提交到 AICAP" / "帮我提交这次改动"（在 AICAP 目录内）

---

### `/xcuitest-skill`
**用途**：为 iOS/iPadOS app 生成 XCUITest UI 测试代码（Swift）。Apple 原生测试框架，覆盖 element 查询、手势、断言、系统弹窗处理、Page Object 模式。默认跑本地模拟器（`xcodebuild test`），也支持 LambdaTest / TestMu 云端真机。

触发："XCUITest" / "iOS UI test" / "Swift UI test" / "XCUIApplication" / "写 iOS 测试"

> 来源：LambdaTest/agent-skills，MIT 许可。附带 `reference/playbook.md` 和 `reference/advanced-patterns.md`。

---

### `/sync-aicap`
**用途**：同步 AICAP skills 到最新版本——`git pull` → 检测变动 → `pnpm run ai:generate` → `pnpm run setup:skills` → 展示新增/删除/更新的 skill 列表。若本地有新 skill，还可自动提交并创建 PR 推给团队。

触发："同步 AICAP" / "sync aicap" / "更新 AICAP" / "拉取最新 skills" / "AICAP 有更新"

---

### `/req-discovery`
**用途**：需求发掘与 User Story 生成——通过多轮结构化访谈（Phase 1 情境锚定 → Phase 2 结构化访谈 + Reflection Gate → Phase 3 提炼），将模糊的产品想法转化为含 Given/When/Then 验收标准和 MoSCoW 优先级的 User Story 列表，可选择直接衔接 `/feature-fullstack` 进入实施。

触发："发掘需求" / "需求访谈" / "帮我写 user story" / "整理需求" / "我有个功能想法"

---

### `/video-hyperframes`
**用途**：生成 Hyperframes / Remotion 兼容的连续帧动画脚本——N 个连续 `<section class="frame">` 帧（1920×1080），每帧表达一个镜头/概念，自带 JavaScript 自动播放（3 秒切换）+ 进度条 + 键盘控制，并输出 `HYPERFRAMES_META` JSON 元数据供 Remotion 渲染成 mp4。

> 来源：nexu-io/open-design `skills/video-hyperframes`。

触发："做一个 hyperframes 视频" / "用 hyperframes 做视频" / "生成帧动画脚本" / "remotion 脚本"

---

### `/plan-eng-review`
**用途**：工程经理视角的方案评审——动手写代码前锁定执行方案：架构、数据流、图示、边界 case、测试覆盖、性能。交互式逐条走查，给出有立场的取舍建议并等你确认方向。

适用：架构/技术方案在实施前的把关，与 `/debate-review`（评审别人的反馈）互补——这个是主动发起评审。

触发：`/plan-eng-review` / "评审这份方案" / "架构评审" / "技术方案评审"

> 来源：zhao-lei007/skills。用 `allowed-tools` + `AskUserQuestion`（Claude 专有），Cursor/Codex 下退化为普通 prompt。

---

### `/plan-ceo-review`
**用途**：创始人视角的方案评审——重想问题、挑战前提、寻找 10 星产品。四种模式：SCOPE EXPANSION（放大梦想）/ SELECTIVE EXPANSION（守住 scope + 精选扩张）/ HOLD SCOPE（最大严谨度）/ SCOPE REDUCTION（砍到本质）。

触发：`/plan-ceo-review` / "从产品/战略层评审这个 plan" / "这个方向对不对"

> 来源：zhao-lei007/skills。

---

### `/pre-land-review`
**用途**：PR 落地前的结构性评审——对比 base 分支 diff，查 SQL 安全、LLM 信任边界越界、条件副作用等测试覆盖不到的结构问题。附带 `checklist.md` / `design-checklist.md` / `greptile-triage.md` 参考文件。

触发：`/pre-land-review` / "合并前帮我评审 diff" / "PR 落地前检查"

> 来源：zhao-lei007/skills，原名 `review`，为避开与 Claude Code 内置 `/review` 命名冲突而重命名为 `pre-land-review`。

---

### `/diagnose`
**用途**：结构化调试难缠的 bug 与性能回归——先建一个 agent 能跑的 pass/fail 反馈回路，再用可证伪假设逐一排查，先写回归测试再改，最后清理 + 复盘。锚定"只有可执行的验证才真正约束调试"。

适用：bug 复现费劲、偶发、看不出根因、性能回归。明显笔误/编译错直接改，不套流程。

触发：`/diagnose` / "调试这个 bug" / "这个 bug 复现不了" / "性能回归变慢了" / "查根因"

> 借鉴 mattpocock/skills `diagnose`，按 AICAP 中文风格本地重写，锚定全局 CLAUDE.md ④（可执行验证）。

---

### `/canvas-design`
**用途**：用"设计哲学"驱动创作 `.png` / `.pdf` 视觉作品——海报、艺术图、静态设计稿。先确立美学运动/设计语言，再视觉化表达，只输出 `.md` / `.pdf` / `.png`。原创设计，绝不抄袭既有艺术家作品（规避版权）。

触发："做一张海报" / "设计一个 X" / "create a poster / art / design"

> 来源：Anthropic skills（含 `LICENSE.txt`）。

---

### `/project-health`
**用途**：系统化评估一个 git 仓库的"项目健康度"——架构合理性、代码规范与精简、目录结构、冗余/死代码、解耦隔离、技术架构、历史评审教训。分四层产出报告：L0 仓库治理/供应链（OpenSSF 风格 + secret 扫描）、L1 静态门禁（knip/vulture/radon/scc/jscpd/dependency-cruiser）、L2 churn×complexity hotspots（纯 git+python 零安装）、L3 AI 语义评审 + cursor-agent 异构终审。

设计：可量化维度一律用可执行探针出客观 JSON（不许 LLM 目测）；探针三态降级（ran_ok / tool_failed / skipped，装了崩绝不当 skip）；secret 扫描只输出规则名+路径不输出值（fail-closed）；软维度异构兜底；结论固化成 lint/fitness rule/ADR。

适用：整仓库健康度评估。不适用：单 PR/diff 评审（用 `/pre-land-review`）。

触发：`/project-health` / "评估项目健康度" / "repo / codebase health" / "查死代码冗余" / "技术债在哪"

> 来源：由一次 `/survey` 调研落地（设计经 2 轮 cursor-agent 异构对抗评审硬化）。

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
