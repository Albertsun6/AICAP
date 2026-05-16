# Phase 2.5：Retrieval Reflection Gate (#3)

> **原则**：Phase 2 三方搜索完成后，主 agent 对照 Brief 跑检查清单——比加辩论轮数更直接对抗 citation hallucination。

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
```

## 追搜决策（主 agent 自决，Yes/No）

- **Yes**：构造定向 prompt（仅针对缺失 / 单源 / vendor-only / 质量不达标的具体点），启动 1 个 cursor-agent（默认异构）或 Claude agent 补搜。最多 1 轮追搜。
- **No**：直接进入 Phase 3-5。
- 决策必须显式写出（不能默默跳过）。

## 输出

Reflection 报告（写入综合报告 §调研 metadata 的子段 `Phase 2.5 Reflection`），含：
- 检查清单 4 项结果
- 追搜决策（Yes/No）与理由
- 若 Yes：追搜 prompt + 追搜结果摘要
