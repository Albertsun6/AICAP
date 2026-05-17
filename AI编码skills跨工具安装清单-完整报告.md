# 常用 AI 编码 agent skills 调研与跨工具安装清单

> /survey 全流程产物（Phase 1→6 + 异构终审收敛）。调研日期 2026-05-17。

## 研究问题
在「跨工具可复用（Claude Code / Cursor / Codex，可经 rulesync 纳入 AICAP SSOT）+ 质量与维护活跃度优先 + 不与现有 survey/debate-review/report-to-html/conventional-commit/project-context 冗余」三约束下，当前社区高频且值得长期依赖的 AI 编码 agent skills 有哪些，应如何分层（必装/可选/观望）推荐安装？

## 评估维度
1. **跨工具可复用性** — tool-agnostic 或可经 rulesync 在三工具复用，而非锁死 Claude 专有 hook/MCP/fork
2. **维护活跃度** — 近 6 月提交、发布节奏
3. **作者可信度** — Anthropic/OpenAI/Vercel 等官方背书 vs 个人弃坑
4. **用途价值与非冗余** — 填补真实缺口，不与已有 5 个 skill 重复
5. **集成成本** — 安装简易度、依赖、纳入 SSOT 摩擦

## 关键背景（多源交叉，high 置信）
- **Agent Skills 已是开放跨工具标准**：Anthropic 2025-12 将 SKILL.md 释为开放标准（agentskills.io），Claude Code / Codex / Cursor / Copilot / Gemini CLI / Cline 等 30+ 工具采纳。SKILL.md = YAML frontmatter + markdown body，body 可移植。证据：[anthropic.com 工程博客](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills); [agentskills.io](https://agentskills.io); [code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills)
- **可移植边界 = hooks / MCP / Claude 专有 `context: fork` / `.claude/agents` 自动派发 / 动态 `` !`cmd` `` 注入**。纯 prompt body 经 rulesync 干净跨三工具；依赖上述任一者跨 Cursor/Codex 退化。证据：[code.claude.com/docs/en/skills](https://code.claude.com/docs/en/skills)（原文 "Claude Code extends the standard"）
- **Cursor 兼容读 `~/.claude/skills/` 与 `~/.codex/skills/`**（[cursor.com/docs/context/skills](https://cursor.com/docs/context/skills)）——对 AICAP SSOT 是利好：Cursor 端可能无需额外 symlink，已有 Claude 目录即被读取（直接关联此前的 symlink 讨论）。

## 方案对比（安装源 = 真实决策对象）

| 源 | 跨工具复用 | 维护活跃 | 作者可信 | 用途价值/非冗余 | 集成成本 | 综合 |
|---|---|---|---|---|---|---|
| **anthropics/skills** | 4 | 5 ✓ | 5 ✓ | 4 | 5 ✓ | **4.6** |
| **wshobson/agents** | 4（纯 md body 可移植，但打包为 Claude Code 插件，跨工具需抽 SKILL.md） | 5 ✓ | 4 | 5 ✓ | 4 | **4.4** |
| openai/skills | 5 ✓ | 4 | 5 ✓ | 3 | 4 | 4.2 |
| vercel-labs/agent-skills | 5 ✓ | 4 | 5 ✓ | 3（仅 Web/Next） | 4 | 4.2 |
| cloudflare/skills | 5 ✓ | 4 | 4 | 2（仅 CF） | 4 | 3.8 |
| VoltAgent/awesome-claude-code-subagents | 4 | 4 | 4 | 4 | 3 | 3.8 |
| VoltAgent/awesome-agent-skills（索引） | 3 | 4 | 3 | 3 | 2 | 3.0 |
| hesreallyhim/awesome-claude-code（索引） | 2 | 4 | 4 | 3 | 2 | 3.0 |
| davila7/claude-code-templates | 2（hooks/MCP 锁定） | 3 | 4 | 3 | 3 | 3.0 |

> ✓ 该维度最优。wshobson 综合分经 Phase 5.5 由 4.6 下调至 4.4（插件打包注记）。

## 主要来源
- [anthropics/skills](https://github.com/anthropics/skills) — 高置信，官方目录，136k★（Phase 5.5 实证）
- [Claude Code Skills 文档](https://code.claude.com/docs/en/skills) — 高置信，开放标准 + 专有扩展边界（Phase 5.5 实证）
- [Cursor Skills 文档](https://cursor.com/docs/context/skills) — 高置信，原生支持 + 兼容读 Claude/Codex 目录（Phase 5.5 实证）
- [wshobson/agents](https://github.com/wshobson/agents) — 高置信，35.5k★、纯 md、活跃（Phase 5.5 实证，附插件打包 caveat）
- [dyoshikawa/rulesync](https://github.com/dyoshikawa/rulesync) — 高置信，v8.18.0、`fetch --features skills`（Phase 5.5 实证）
- [agentskills.io](https://agentskills.io) / [Anthropic 工程博客](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) — 开放标准 primary
- [openai/skills](https://github.com/openai/skills)、[developers.openai.com/codex/skills](https://developers.openai.com/codex/skills)、[vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills)（~26k★）、[cloudflare/skills](https://github.com/cloudflare/skills) — 中置信（Agent X 单源 primary，URL 存活）

## 推荐 — 分层安装清单

**结论**：不要批装 awesome 清单；从 `anthropics/skills`（官方、最高信任）精选 + 按栈从 `wshobson/agents` 抽 SKILL.md body，统一经 rulesync 纳入 AICAP SSOT。

### Tier 1 必装（官方、可移植、补真实缺口、不与现有 5 skill 冗余）
| skill | 源 | 为什么 |
|---|---|---|
| `skill-creator` | anthropics/skills | 元技能：规范地创作/维护 skill——直接服务 AICAP SSOT 自身维护；纯 prompt 可移植 |
| `webapp-testing` | anthropics/skills | 浏览器/E2E 测试通用能力；ios-e2e-test 是 Seaidea 专属且未入 SSOT，此为通用补位；纯 prompt 可移植 |

**Tier1 为何是 Anthropic（证据化 tie-breaker，回应异构终审）**：并非"Anthropic 默认优先"。`skill-creator`/`webapp-testing` 是**与栈无关的通用能力缺口**，直接服务 SSOT 自身；而 [openai/skills](https://developers.openai.com/codex/skills)（官方 Codex Skills Catalog，"build on the open agent skills standard"）与 anthropics/skills **功能重叠**——同一能力的 Codex 镜像，且 AICAP 经 rulesync 已生成 Codex 产物，无需重复引入；[vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills)（~26k★ 官方）、cloudflare/skills 是**平台栈专属**（React/Next、Cloudflare），按"用途价值/适用条件"维度归 Tier2。即 Tier1 由"通用性 + 非冗余"两维度筛出，非作者身份。

### Tier 2 可选（按技术栈/工具/需求触发，不默认装）
- `mcp-builder`（anthropics/skills）— **条件必装**：仅当 AICAP 实际开发 MCP server 时。现状：AICAP 有 `.mcp.json`（消费 MCP）但无自建 server 证据，故归 Tier2 而非 Tier1（经异构终审修正）
- `frontend-design` / `web-artifacts-builder`（anthropics/skills）— 仅做 Web UI 时
- `vercel-labs/agent-skills` — React/Next/Vercel 栈项目
- `cloudflare/skills` — Cloudflare 平台项目
- document skills `docx/pdf/pptx/xlsx`（anthropics/skills）— 生成 Office/PDF 时；**注意 source-available 许可 + 绑脚本（Tier 2 可移植性）**
- 从 `wshobson/agents` cherry-pick code-review / test-fix 类 workflow skill 的 SKILL.md body（不消费其插件打包）

### Tier 3 观望（先审计，勿批装）
- `VoltAgent/awesome-agent-skills`、`hesreallyhim/awesome-claude-code` — 仅作发现索引，非信任边界
- `davila7/claude-code-templates` — hooks/MCP 锁定，跨工具退化，发布节奏慢
- 2026 新出的安全/三方 skill 包 — 采纳前过下方审计 checklist

### 第三方 skill 安装前审计 checklist（回应异构终审，替代笼统"生态变动快"）
装任何非官方 skill 进 SSOT 前逐项核：
- [ ] **维护者**：组织 vs 个人；近 6 月有无提交；issue 是否有人响应（防弃坑）
- [ ] **许可**：repo license 是否允许再分发；SKILL.md frontmatter 是否声明 `license`（[agentskills.io/specification](https://agentskills.io/specification) 为可选字段，可能缺失或后改）
- [ ] **spec 兼容**：是否用了 `compatibility` / `allowed-tools` / `context: fork` 等工具实现支持度不一的字段——跨 Cursor/Codex 会静默退化
- [ ] **脚本/权限**：bundled scripts 是否被审过；`allowed-tools` 是否过度授权
- [ ] **冗余**：是否与现有 survey/debate-review/report-to-html/conventional-commit/project-context + Tier1 重叠

### 安装机制（Phase 5.5 实证语法）
```bash
# 把官方 skill 拉进 SSOT 源（rulesync fetch 语法已实证）
rulesync fetch anthropics/skills --features skills
# 仅保留 Tier 1（skill-creator / webapp-testing）目录到 .rulesync/skills/，删掉不需要的
# 然后按 AICAP 既有流程生成三工具产物
pnpm run ai:generate   # = rulesync generate --targets "*" --features "*"
```
> `rulesync install` 子命令存在性 **待验证**（见下）。AICAP 既有 `pnpm run ai:generate` 是确定可用路径。

**理由**：anthropics/skills 与 rulesync 在质量+维护两维度均 ✓（136k★ / v8.18.0 均 Phase 5.5 实证）；Tier1 两项纯 prompt、补 SSOT 真实缺口且与现有 5 skill 不重叠；反证搜索表明批装 awesome 清单会引入大量 hook/MCP 绑定项跨工具退化，故走 cherry-pick。

**适用条件**：适用于"以 rulesync 为 SSOT、要三工具一致"的 AICAP 场景。若只用单一工具，或需要 Claude 专有 hook 编排，则 Tier 3 锁定项的排序需重估。做 MCP server 开发则 `mcp-builder` 升 Tier1。

**置信度**：中高（基于 10+ primary 源 + Phase 5.5 五抽样 4 supported / 1 partial + 异构终审 Refine 收敛）。

## 待验证风险
- [ ] `rulesync install` 子命令是否存在 — Agent X 单源 CLI 声明；验证 `rulesync --help`（fetch/generate 已实证，install 未证）
- [ ] wshobson/agents 最近提交确切新鲜度 — "2026-05-17" 未证实；当前仅能确认"383 commits、持续活跃"
- [ ] vercel-labs/agent-skills、cloudflare/skills、openai/skills 的具体 skill 列表与质量 — Agent X 单源，URL 存活但未深审内容
- [ ] wshobson 中 code-review/test-fix 的确切 skill slug — 类别已确认，具体名需进仓库核对再装
- [ ] anthropics document-skills 为 source-available（非 OSS）— 纳入 SSOT 再分发前需核许可
- [ ] skill 生态变动快（标准 2025-12 才开放）— >18 月的清单文章排名不可信，装前核仓库现状

## 调研 Metadata
- **Phase 2.5 Reflection**: 子问题 5/5 覆盖；核心 claim 多源；无 vendor-only 关键 claim；质量分布 High≫30%/Low≪30%；追搜决策=No
- **Phase 5.5 Citation Health**: Layer A 41 URL / 39 ok / 1 blocked / 1 dead(2%) → PASS；Layer B 5 抽样 → 4 supported / 1 partial(wshobson 插件打包+日期) / 0 not-supported → PASS
- **Phase 6 异构终审 verdict**: Refine（reviewer 同意主结论，提 3 点补充）
- **辩论收敛**: Round 1 主 agent 判断矩阵 3 条全 accept → 自动收敛，跳过 Round 2/3
- **人类介入**: 无
- **Output**: /Users/yongqian/Desktop/AICAP/AI编码skills跨工具安装清单-完整报告.md
- **Filename collision**: none
- **Audio**: /Users/yongqian/Desktop/AICAP/AI编码skills跨工具安装清单-音频概要.m4a

#### Phase 6 辩论历史（Round 1，verdict=Refine）

##### Round 1：主 agent 判断矩阵
| reviewer 建议 | 立场 | 论据 / 证据 |
|---|---|---|
| Tier1 全 Anthropic，需补证据化 tie-breaker | accept | 已加"Tier1 为何是 Anthropic"段：通用能力缺口 vs openai/skills 功能重叠（rulesync 已生成 Codex 产物）vs vercel/cloudflare 平台栈专属。证据 developers.openai.com/codex/skills; github.com/vercel-labs/agent-skills |
| mcp-builder Tier1 证据弱 → 条件必装 | accept | 核查 AICAP 仅有 .mcp.json（消费），无自建 server 证据 → mcp-builder 移 Tier2 条件必装；Tier1 收紧为 skill-creator + webapp-testing |
| 风险段补维护者/许可/spec 漂移审计 checklist | accept | 已加"第三方 skill 安装前审计 checklist"5 项；引 agentskills.io/specification 可选字段工具支持度不一 |
