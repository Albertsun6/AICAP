# Phase 1 + Phase 1.5：问题界定 + Research Brief

> **前提**：进入 Phase 1.5 前必须 Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/brief-template.txt`（见 SKILL.md §Prompt Template Read Gate）。

## Phase 1：问题界定（防止确认偏差，先于搜索）

**做什么**：
1. 将用户输入标准化为一个可评估的研究问题（"如何做X" → "在Y约束下，做X的最佳方案是什么"）
2. 定义 3-5 个评估维度（**必须在搜索前确定**，防止事后根据搜索结果选维度）
   - 常见维度：复杂度 / 性能 / 社区活跃度 / 学习曲线 / 维护成本 / 适用场景
   - 按用户场景定制，不要套通用模板
3. 写出初始假设（你认为哪个方向可能最优，搜索完再对照）

**输出**：研究问题陈述 + 评估维度列表 + 初始假设（内部使用，不展示给用户）

---

## Phase 1.5：Research Brief（**foundational**，所有下游 agent 对照）

> **原则**：Phase 1 后产出一份冷冻 Brief，作为 north star。Phase 2 三 agent、Phase 2.5 反射 gate、Phase 5 综合、Phase 6 终审全部对照 Brief 验收——消除"三 agent 各跑歪不在同一靶子上"的最大失败模式。

**Brief 模板路径**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/brief-template.txt`（Read gate 见 SKILL.md §Prompt Template Read Gate）

按当前研究填字段，内存中持有作为 north star；Phase 2 给 Agent A/B/X 的 prompt prefix 强制注入 Brief 全文；Phase 6 终审 prompt 也注入作为对照标准。

**Brief 必含字段（invariants）**：
- **研究问题** / **评估维度（3-5）** / **子问题清单** / **排除范围**
- **成功标准**：默认 ≥8 source、近 12 月源 ≥30%、primary source 占比 ≥40%
- **信源约束**：`allowed_domains` / `blocked_domains`（默认含中文社区 baseline）/ `source_freshness` / `source_connectors`（MCP 占位）

### Trusted Source Scope（#7）何时升 P0

当 /survey 扩展到以下任一场景，**Trusted Source Scope 必须升为强制字段**而非可选：
- 私有文档 / 内部知识库调研
- 指定站点 allowlist 模式（如仅 gov / edu / 内部 wiki）
- 启用 MCP source connectors（Google Drive / Gmail / GitHub / Slack / Microsoft 365 类）
- source freshness 严格要求（金融 / 医疗 / 安全场景）

当前默认仍是 P1（开放 Web 调研可选填）。
