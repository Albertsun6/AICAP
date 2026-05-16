---
description: 调研任意话题：网上别人怎么做 → 结构化对比 → 评估 → 建议
targets: ["*"]
---

Run the `survey` skill workflow on: $ARGUMENTS

**默认使用 Deep 模式**（3 个独立 Agent 并行搜索，互相不可见，最后综合）。
加 `--quick` 切换为单 Agent 快速模式。加 `--save` 追加结果到 docs/IDEAS.md。

Workflow:

1. **Phase 1 — 问题界定**：将输入标准化为研究问题，定义 3-5 个评估维度（先于搜索确定，防止事后选维度），写出初始假设。

2. **Phase 2 — 并行研究**（Deep 默认）：启动 3 个独立 Agent：
   - Agent A：通用方案 + 主流观点（Web、官方文档）
   - Agent B：技术实现 + 开源项目（GitHub、技术博客）
   - Agent C：社区反馈 + 踩坑经验（HN、Reddit、Stack Overflow）
   三个 Agent 互相不可见，防止确认偏差。

3. **Phase 3 — 对比矩阵**：综合 A/B/C 发现，构建候选方案 × 评估维度表格，1-5 打分，标注数据不足格（?），标出三个 Agent 之间的分歧点。

4. **Phase 4 — 冲突分析**：标出来源分歧，主动为领先方案寻找反证，评定置信度（高/中/低）。

5. **Phase 5 — 建议输出**：一句话结论 + 选择理由 + 适用条件 + 置信度声明 + 待验证风险。

Hard rules:
- 每个关键结论 ≥ 2 个独立来源
- 每个来源最多 fetch 2 页，保持聚焦
- 数据不足时明确说，不填空分
- 不写代码，不实施，只做研究
