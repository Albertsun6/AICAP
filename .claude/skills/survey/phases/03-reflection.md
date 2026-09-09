# Phase 2.5：Retrieval Reflection Gate (#3)

> **原则**：Phase 2 四路搜索完成后，主 agent 对照 Brief 跑检查清单——比加辩论轮数更直接对抗 citation hallucination。

**触发**：Phase 2 完成 / Phase 3 综合前。

## 检查清单

```text
1. 子问题覆盖率：Brief 的每个子问题，至少 1 条 Compressed Finding 覆盖？
   - 缺失子问题 → 列出，进入"追搜决策"
2. 独立来源数：每个关键 claim 至少 2 个独立 source（domain 不同）？
   - 单源 claim → 标记低置信，进入"追搜决策"
3. Vendor-claim 依赖：是否存在仅靠 vendor 自家声明 / Series A 公告 / 招聘软文 支撑的关键 claim？
   - 列出，进入"追搜决策"
4. Source 质量分布（用 ../references/source-quality.md 评分）：
   - High 占比 ≥30%？Low 占比 ≤30%？
   - 不达标 → 进入"追搜决策"
5. 前提完整性：搜索结果是否推翻了 Brief 的前提（如比较对象已废弃/被合并、
   用户场景下某选项根本不可用、用户问的 X 实际是另一回事）？
   - 前提破裂 → 进入"回问用户"（不进追搜决策、不自行改靶）
```

## 前提破裂 → 回问用户（不自行改靶）

Brief 是冷冻的，改靶必须经用户——搜索发现前提错误时**不许默默换研究问题**：

- 带证据发起**一次** AskUserQuestion：`按原题继续（结论会标注前提风险） / 换靶（回 Phase 1 重立 Brief）`
- 用户选换靶 → **回 Phase 1 重走**（不是 1.2——新靶子的研究问题标准化、评估维度、初始假设都要重做，
  只回提问 Gate 会让新 Brief 沿用旧维度），产出 **Brief v2**，必要时经 1.2 澄清。**重入必须重新 Read**
  `01-question-framing.md` + `prompts/brief-template.txt` 并 state `Reloaded Phase 1+1.2+Brief template (v2)`——
  这时距上次 Read 已隔很长上下文，凭记忆重演正是 skill 要防的 decay
- **旧结果不许直接算数**：已有搜索结果逐条映射到 Brief v2 的子问题并核对信源约束后才可复用；
  映射不上的不计入 v2 的覆盖率与 source 数分母
- **换靶 = 开启新预算轮**：cursor-agent 调用计数清零，X1/X2 允许对 Brief v2 各再跑 1 次
  （见 `06-debate.md` §iteration bound 换靶例外）——否则新靶子零异构覆盖，违反「异构两路不可省」。
  **换靶整个 survey 最多发生 1 次**（第二次前提破裂只能按原题继续+标注风险），防无限循环
- 非交互降级同 Phase 1.2：按原 Brief 继续，报告顶部披露前提风险，metadata 记 `前提破裂: <证据>, 未经用户裁决`

## 追搜决策（主 agent 自决，Yes/No）

- **Yes**：构造定向 prompt（仅针对缺失 / 单源 / vendor-only / 质量不达标的具体点），启动 1 个异构 agent（默认 `run-cursor-agent.sh … gemini`，同步）或 Claude agent 补搜。**不用 codex**——搜索路它比 cursor 慢，而追搜是串行门。最多 1 轮追搜。
- **No**：直接进入 Phase 3-5。
- 决策必须显式写出（不能默默跳过）。

## 输出

Reflection 报告（写入综合报告 §调研 metadata 的子段 `Phase 2.5 Reflection`），含：
- 检查清单 5 项结果（含前提完整性；触发回问的记用户裁决结果）
- 追搜决策（Yes/No）与理由
- 若 Yes：追搜 prompt + 追搜结果摘要
