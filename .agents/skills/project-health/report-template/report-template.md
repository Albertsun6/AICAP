# <仓库名> — 项目健康度报告

> 评估日期：<date> ｜ 方法：/project-health（L0 治理 · L1 门禁 · L2 趋势 · L3 AI+异构语义）
> 目标仓库：<path> ｜ 技术栈：<stack> ｜ 评估窗口：<since>

## 健康画像（分层，非单一分数）

```
L0 治理   <●○ 条>   <一句话>
L1 门禁   <●○ 条>   <一句话>
L2 债震中 <●○ 条>   <一句话>
L3 软维度 <●○ 条>   <一句话>
```

> ⚠️ <仅在 cursor-agent 不可用时出现：软维度未经异构审查，架构/解耦结论高风险，建议人工复核>

## 维度评分（对照 rubric/thresholds）

| 维度 | 分 | 依据（引 probes.json 数字 / file:line / 异构 verdict） |
|---|---|---|
| D0 仓库治理 | <1-5/?> | <license/secret/分支保护/bus factor 实测> |
| D1 架构及框架合理性 | <1-5/?> | <循环依赖数 + L3 异构结论> |
| D2 代码规范，代码精简 | <1-5/?> | <复杂度/MI/lint 实测> |
| D3 目录结构合理性 | <1-5/?> | <orphans + L3> |
| D4 冗余文件，无用文件 | <1-5/?> | <knip/vulture/jscpd 实测> |
| D5 内容隔离，解耦 | <1-5/?> | <no-circular/instability + L3> |
| D6 技术架构合理性 | <1-5/?> | <top hotspots> |
| D7 历史评审教训 | <1-5/?> | <有无 ADR/固化规则 + 复发> |

> `?` = 工具未装/数据不足，已在下方"覆盖边界"列出。

## L2 技术债震中（churn × complexity hotspots）

| # | 文件 | revisions | loc | score_norm | 交叉判读 |
|---|---|---|---|---|---|
| 1 | <file> | <n> | <n> | <0-1> | <是否高复杂度/高重复/上帝模块> |

## L3 软维度评审（AI + 异构）

每条：结论 + file:line 证据 + 置信度 + 异构 verdict（Concur/Refine/分歧人裁）。

## 最该先动的 3 件事（按 ROI）

1. <action> — <为什么（交叉 hotspot + 维度分）> — 固化：<lint/fitness/ADR/补文件>
2. ...
3. ...

## 固化清单（教训 → 自执行规则）

| 发现 | 固化动作 | 可机器检查? |
|---|---|---|
| <循环依赖 X→Y> | <dependency-cruiser no-circular 规则进 CI> | 是 |
| <架构决策 Z> | <写 ADR docs/adr/NNN> | 仅留档 |

## 覆盖边界（诚实声明）

- 自动覆盖：<维度/层>
- 半自动（AI+异构）：<维度>
- **未覆盖（工具 skip）**：<维度> → 安装指令：<cmd>

## 调研 / 评估 Metadata

- 探针：ran <N> / skipped <M>（manifest: <outdir>/probes.json）
- L3 异构终审 verdict：<Concur/Refine/Dissent>
- 辩论收敛：<Round 1 全 accept / Round N 收敛 / 人类裁决>
- 人类介入：<无 / 裁决 K 条>
- 降级：<cursor-agent 不可用? 非 git? 报告写盘?>
