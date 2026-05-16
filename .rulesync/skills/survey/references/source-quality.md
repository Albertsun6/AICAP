# Source Quality Helper

> 被 Phase 2 (Sub-agent 写 Source Inventory) / Phase 2.5 (Reflection Gate) / Phase 5.5 (Citation Health) / Phase 6 (终审优先信任) 共用。独立文件避免 phase 间循环依赖。

## 原则

启发式打分，不依赖外部 API。每个 source 写到 Source Inventory 时附 Quality 评分。

## 评分维度

| 维度 | 加 / 减分 |
|---|---|
| Domain TLD | `.gov` +3；`.edu` +2；官方域名（openai.com / anthropic.com / google.com / cloud.google.com / microsoft.com / *.openai.com 等 vendor 官方）+2；`.com` 中立 0；内容农场 / 二手转述聚合站 -2 |
| 发布日期 | 近 6 月 +1；6-12 月 0；>12 月 -1；无日期 -2 |
| 来源类型 | primary（官方 docs / spec / arxiv paper / official blog）+2；secondary（reputable news / 知名工程师 blog）+1；tertiary（aggregator / wiki / SEO blog / Medium 二次解读）0 |
| 跨源引用（可选）| 出现在 ≥3 个其他可信 source 中 +1 |

## 评分汇总

- 总分 ≥5：**High** quality
- 总分 3-4：**Medium**
- 总分 ≤2：**Low**

## 用途

- **Sub-agent**（Phase 2 Agent A/B/X）：写 Source Inventory 时填 Quality 列
- **Phase 2.5 Reflection Gate**：检查 High 占比 ≥30% / Low 占比 ≤30%
- **Phase 5.5 Citation Check**：报告里按 Quality 分层统计
- **综合 agent 与 Phase 6 终审**：优先信任 High，对 Low source 要求 ≥2 独立来源交叉验证
