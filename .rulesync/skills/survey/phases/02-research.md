# Phase 2：多源研究

> **强制异构搜索**：Phase 2 始终是 2 Claude + 1 cursor-agent，无用户可控的 opt-out。仅当 cursor-agent 不可用时自动降级（见下方 §cursor-agent 不可用时的自动降级）。

## 默认模式（2 Claude + 1 cursor-agent 并行）

Phase 1.5 Brief 完成后，启动 3 个并行 agent——其中 1 个是 **cursor-agent (GPT-5.5-medium)**：

```
Agent A（Claude，通用 + 主流）
  任务：搜索通用方案概览、官方文档、权威博客
  禁止：不看 Agent B/X 的搜索结果
  工具：WebSearch, WebFetch

Agent B（Claude，技术 + 实现）
  任务：搜索开源项目实现、技术论文、GitHub 仓库
  禁止：不看 Agent A/X 的搜索结果
  工具：WebSearch, WebFetch

Agent X（cursor-agent，异构 lens）— 替换原 Claude Agent C
  调用方式：见下方 §cursor-agent 调用方式
  任务：4 类 Claude 易盲区针对性搜索
```

**Agent X cursor-agent prompt 模板路径**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/agent-x.txt`（Read gate 见 SKILL.md §Prompt Template Read Gate；调度方式见 §cursor-agent 调度）

主 Claude 在 prompt 模板顶部注入 Brief 全文作为 prefix（agent-x.txt 已留占位符）。

**Agent X 模板硬约束（invariants）**：
- **4 类 Claude 盲区显式覆盖**：训练截点后新工具 / Anthropic 生态偏移 / "主流"定义偏差 / 小众但成熟方案
- **信息源排除**：不搜中文社区（CSDN / 掘金 / 思否 / 简书 / 知乎技术专栏 / 微信公号 / gitee / 国产 SaaS）；日文/俄文/欧洲方案如出现英文索引中可保留，不主动用非英文关键词
- **输出强制二段式**（#5 Context Isolation）：`## Compressed Findings` (~500 字 / 5-8 条 finding 标 confidence + URL) + `## Source Inventory`（URL / 摘要 / 日期 / 标签 / Quality）
- 最少 5 个 source，最少 1 个近 12 月（按 currentDate 算）

综合 agent 收到三方结果（A+B+X）后合并；分歧点保留，**特别标注 Agent X 独有的 source**（即"Claude 没搜到、cursor-agent 搜到的"——这是异构核心价值的体现）。

**并发协调**（主 Claude 必读）：
- Agent A、B 是 Claude subagent（用 Agent/Task 工具启动）
- Agent X 是外部 Bash subprocess（调 `run-cursor-agent.sh`）
- 三者**并发启动**——同一回合 message 内同时发 2 个 Agent 工具调用 + 1 个 Bash 工具调用
- 主 Claude 在收到三方返回后再启动综合 agent；不要串行启动 X，会拖延 ~3 min

## Sub-agent 输出格式（强制 #5 Context Isolation）

> **原则**：sub-agent 完整 markdown 报告（~3000 字）回到综合 agent 时会撑爆 context。Anthropic 工程 blog 明确说"isolated context windows is biggest single win"。所有 sub-agent（A / B / X、以及 Phase 2.5 追搜 agent）**必须**返回二段式：

```text
## Compressed Findings（~500 字，硬上限 800 字）

5-8 条核心发现，每条格式：
- **<finding title>** [confidence: high/medium/low]
  <一句话内容>。证据：<URL1>; <URL2>

## Source Inventory（结构化完整来源）

| URL | 一句摘要 | 发布日期 | 标签 | Source Quality 评分 |
|---|---|---|---|---|
| https://... | ... | YYYY-MM-DD | primary/secondary/official/blog/paper | High/Medium/Low（见 ../references/source-quality.md） |
| ... |
```

**综合 agent 读取规则**：
- 默认只读三方的 Compressed Findings + Source Inventory
- 遇到分歧或需要溯源时，才回查 sub-agent 原文（通过 agentId SendMessage 询问，或要求 sub-agent 补充）
- 不要把三方完整 3000 字报告全塞进综合阶段 context

## cursor-agent 不可用时的自动降级（3 Claude）

cursor-agent CLI 不可用（`command -v cursor-agent` 失败）或调用失败 / 超时（>300s）时，**自动**退回到 3 Claude 经典并行——用户无法主动选择此路径，仅作为 fallback：

```
Agent A（通用 + 主流）
  任务：搜索通用方案概览、官方文档、权威博客
  禁止：不看 Agent B/C 的搜索结果

Agent B（技术 + 实现）
  任务：搜索开源项目实现、技术论文、GitHub 仓库
  禁止：不看 Agent A/C 的搜索结果

Agent C（社区 + 经验）
  任务：搜索 HN/Reddit/StackOverflow 上的讨论、踩坑经验、真实反馈
  禁止：不看 Agent A/B 的搜索结果
  信息源排除：不主动用中文关键词搜索；不优先使用 CSDN/掘金/思否/简书/知乎技术专栏/
              微信公众号/gitee/国产 SaaS 作为论据（用户反馈：中文社区信息杂乱落后）
```

**并行独立的原因**：三个 Agent 各自独立搜索，防止一个 Agent 的早期发现锁定后续搜索方向；A/B/C 视角天然不同，分歧点本身就是最有价值的信息。

**报告顶部加 banner**（不是末尾埋）：

```markdown
> ⚠️ **HETEROGENEOUS REVIEW: SKIPPED**
> Reason: <cursor-agent not found | timeout >5min | auth failure | empty output>
> Implication: 所有 source 来自 Claude lens，训练数据盲区未被独立模型审查；高风险决策建议安装 cursor-agent 后重跑（cursor.com/cli）
```

**绝不**因异构失败让主流程失败。

## cursor-agent 调度（最小硬约束）

- **必须调用 cursor-agent 跑 Agent X**（异构 lens 是 Phase 2 设计核心）
- **不可用时降级到 3 Claude**（Agent X 换 Agent C）+ 报告顶部 banner（见上方 §cursor-agent 不可用时的自动降级）
- **失败不阻塞主流程**——降级是设计目标，不是异常

具体调用方式（4 硬点 / exit code 表 / Bash timeout / prompt 文件命名规范）见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)，**进入本段前必须 Read helper**。
