# Phase 6：异构终审 + 多轮辩论

**始终执行**：cursor-agent 异构终审 + 主 agent 判断矩阵 + 最多 3 轮辩论 + 剩余分歧人类裁决。**无 opt-out**——/survey 是高质量调研 skill，Phase 6 是质量门禁不是可选项。

> **`finalize` 语义统一定义**：本文档所有 `finalize` 指代 → 进入 [`phases/04-synthesis.md`](04-synthesis.md) §Finalize 输出步骤（写 cwd 报告 + audio）。**只有** Phase 6 收敛（Round 1 全 accept / Round 2/3 双方同档 / 人类裁决完成）后才允许触发 finalize；之前任何 round 的中间矩阵 / rebuttal 都**禁止**写 cwd 文件。

cursor-agent 不可用时整段 Phase 6 跳过 + 顶部 banner（见 `../phases/02-research.md` §cursor-agent 不可用时的自动降级）。

## 设计原则

cursor-agent 终审是**独立 lens 的意见**，不是"权威修订指令"。主 agent 必须对每条建议表态；剩余分歧由人类裁决而非 AI 共识收敛——防止 Claude 与 GPT-5.5 共享盲区时的"AI 回声室"。

## 工作流（线性 7 步）

1. **Round 1**：cursor-agent 终审 → verdict
   - Concur → 写最小 metadata，结束
   - Refine / Dissent → 主 agent 4 档判断矩阵
2. **收敛检查 1**：全 accept → finalize；否则进 Round 2
3. **Round 2**：cursor-agent rebuttal 非 accept 条目 → 主 agent 二轮判断（维持原档 OR 让步并改档，必附论据）
4. **收敛检查 2**：双方同档（无分歧）→ finalize；否则进 Round 3
5. **Round 3**：cursor-agent 二次 rebuttal → 主 agent 三轮判断（同 Round 2 规则）
6. **收敛检查 3**：双方同档 → finalize；仍分歧 → 进人类裁决
7. **人类裁决**：AskUserQuestion 暴露分歧条目（>4 条分批 ≤4），每条 options = 采纳主 agent / 采纳 cursor-agent / 独立判断；用户最终立场 → finalize（不再回 cursor-agent）

## Round 1：cursor-agent 异构终审

**输入**：Phase 5 完整报告 markdown

**Round 1 prompt 模板路径**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/round1.txt`

**调度**：Round 1 必须调用 cursor-agent；失败时跳过 Phase 6（不进人类裁决）。注入内容：Brief + Source Quality 评分汇总（见 `../references/source-quality.md`）+ Phase 2.5 Reflection 结果（见 `../phases/03-reflection.md`）+ Phase 5.5 Citation Health（见 `../phases/05-citation.md`）。具体调用方式（exit code / timeout / prompt 文件命名规范）见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)，**进入本段前必须 Read helper**。

**Round 1 模板硬约束（invariants，cursor-agent 必须按这 7 个角度评审）**：
1. **Agent X 降权检查**：是否有 Agent X 上报但被 Claude 降权 / 丢弃的 source 或方案
2. **Claude 偏好检查**：推荐是否非证据驱动地排 Anthropic 系工具靠前
3. **风险覆盖检查**：待验证风险是否覆盖训练截点后的版本变化 / maintainer 离职 / license 改变
4. **Brief 对照**：子问题清单全答？成功标准达标？信源约束遵守？
5. **Source Quality 对照**：High 质量 source 被用？Low source 是否 ≥2 独立来源交叉验证？
6. **Citation Health 对照**：dead URL / not-supported claim 是否有适当 caveat？
7. **信源排除**：补搜不搜中文社区

输出 verdict：Concur / Refine / Dissent；每条建议附 URL 证据，便于多轮辩论。

## Round 1 主 agent 判断矩阵

收到 cursor-agent verdict 后：

- **Concur 路径**：跳过矩阵；§metadata 写一行 `Phase 6 verdict: Concur; no changes requested; no additional claims introduced`（表达"reviewer 未提出修订"而非"报告无偏见"，防误读为权威背书）→ 进入 finalize（Phase 4）
- **Refine / Dissent 路径**：对**每一条建议**做 4 档表态，写入 §metadata 子段 `Phase 6 辩论历史 > Round 1`

**4 档判断规则**：
- **accept**：证据扎实、与主结论方向一致 → 直接 incorporate
- **partial**：证据部分成立但需打折 / 限定范围 → incorporate 时加 caveat
- **defer**：建议可能成立但证据强度不够支撑强表述 → 不 incorporate 为事实，放入 §待验证风险 或低置信度备注（典型例子：Series A 公告"采用"声明、未独立验证的产品宣传数据）
- **refute**：不 incorporate。必须标 `reason: unsupported`（reviewer 证据不足）或 `reason: contradicted`（主 agent 有反证，必附 URL / 引文）

**禁止**：
- 不要 refute 仅因"我不同意"——必须给 reason
- 不要 accept 仅因"权威给的"——必须给独立证据支持
- 不要把 partial / defer 当 escape hatch 用于规避表态

**Round 1 收敛条件**：全部 accept → 进入 finalize（Phase 4），跳过 Round 2/3。

## Round 2：cursor-agent rebuttal + 主 agent 二轮判断

仅当 Round 1 后存在**非 accept** 条目（partial / defer / refute）时触发。

**调度**：Round 2 调用 cursor-agent；失败时**提前进入人类裁决**（带 metadata banner 标注"AI 辩论未跑满 3 轮"）。注入内容：Round 1 矩阵（仅非 accept 条目）+ 主 agent 论据。

**Round 2 Rebuttal prompt 模板路径**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/round2-rebuttal.txt`（调度同 Round 1，见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)）。

**Round 2 模板硬约束（invariants）**：
- **仅反驳非 accept 条目**（partial / defer / refute）；accept 已收敛不重新挑起
- **三档反驳规则**：partial（限定是否合理）/ defer（证据是否够升 accept）/ refute（unsupported 补来源 / contradicted 回应反证）
- **允许撤回**：被主 agent 说服则明确"我撤回 Round 1 建议"，不勉强反驳
- **信息源排除**：同 Round 1（禁中文社区）

**主 agent 二轮判断**：读完 cursor-agent rebuttal 后，对每条做新表态：

| 维持 / 让步 | 必备字段 |
|---|---|
| **维持原档** | 必附"为什么不被反驳说服"的论据（≥1 句；不能仅"我还是不同意"） |
| **让步并改档** | 必附"被哪个新证据/论据说服"（指向 cursor-agent rebuttal 里具体句段） |

**禁止**：
- 不要让步仅因为"对方反驳得更激烈"——必须有新证据触发
- 不要维持仅因为"我已经写下来了"——必须有未被反驳触及的独立证据

**Round 2 收敛条件**：所有条目双方同档（全部 accept / 全部 partial 同 caveat / cursor-agent 全部撤回 Round 1 建议）→ finalize（Phase 4）。

## Round 3：cursor-agent 二次 rebuttal + 主 agent 三轮判断

仅当 Round 2 后仍有分歧条目时触发。

**调度**：Round 3 调用 cursor-agent；失败时**提前进入人类裁决**（同 Round 2 处理）。注入内容：Round 2 后**仍分歧**的条目 + 主 agent 二轮论据。调度方式见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)。

**Round 3 cursor-agent prompt 与 Round 2 同结构**，但 prefix 加一句：

```text
这是辩论第 3 轮（最后一轮 AI 辩论）。之后剩余分歧将由人类裁决。所以这一轮请：
- 只对 Round 2 主 agent 给的新论据反驳；不要重复 Round 1/2 已被讨论的点
- 如果你认为已经穷尽证据但仍坚持原意见，明确写 "证据已穷尽，分歧应由人类裁决"
- 如果你认为主 agent 二轮论据有道理，撤回前述意见
```

**主 agent 三轮判断**：同 Round 2 规则。

**Round 3 收敛条件**：双方同档 → finalize（Phase 4）；仍有分歧 → 进入人类裁决。

## 人类裁决

**触发**：Round 3 后仍有 ≥1 条分歧（双方未同档）。

**执行**：用 AskUserQuestion 暴露每条分歧。

格式约束：
- 每条分歧作为独立 question
- options 至少 3 个：`采纳主 agent 立场` / `采纳 cursor-agent 立场` / 实质性独立判断（如 `维持 defer 但范围更窄`、`改 accept 但加强 caveat` 等具体替代）
- 分歧条目 ≤4 → 一次性问；>4 → 分批每批 ≤4

**用户裁决后**：
- 按用户最终立场 finalize（Phase 4）
- 不再回 cursor-agent 重审（人类即终审）
- §metadata 记录用户裁决 + 备注

## iteration bound

- AI 辩论最多 3 轮（Round 1 + Round 2 rebuttal + Round 3 rebuttal）
- cursor-agent 总调用 ≤ 3 次（即使 Round 1 直接 Concur 也算 1 次）
- 主 agent 判断 ≤ 3 次
- 人类裁决 1 次（不可循环）

## 降级

- cursor-agent Round 1 不可用 → 跳过整个 Phase 6，报告顶部 banner 已涵盖
- cursor-agent Round 2 / Round 3 调用失败 → 提前进入人类裁决（带 metadata banner 标注"AI 辩论未跑满 3 轮"）
- AskUserQuestion 不可用（极少情况）→ §metadata 标注 "分歧未裁决"，正文不 incorporate 分歧条目
