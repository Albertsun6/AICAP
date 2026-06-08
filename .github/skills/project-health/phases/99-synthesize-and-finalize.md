# Phase 99 — 综合评分 + 固化规则 + 落报告

> 进入前 Read 本文件 + `rubric/dimensions.md` + `report-template/report-template.md`，state "Loaded synthesis"。

## 1. 综合评分

按 `rubric/dimensions.md` 给每个维度打分 + 证据。规则：
- **可量化维度的分必须来自 `probes.json` 数字**，不是 LLM 印象（对照 `rubric/thresholds.md`）。
- 软维度（L3）的分带"异构 verdict"标注（Concur/Refine/分歧人裁）。
- 工具 skip 的维度标 `?`（数据不足，不填空分——同 survey 不强行有答案）。
- 给一个总体 health 画像（**不是单一神奇分数**——分层展示：L0 治理 / L1 门禁 / L2 债震中 / L3 软维度各自结论）。

## 2. 固化：教训 → 自执行规则（闭环，invariant 4）

这是本 skill 区别于"跑一遍工具就完"的关键。每条 actionable 发现，给出**怎么变成下次自动拦截的规则**：

| 发现类型 | 固化动作 |
|---|---|
| 循环依赖 / 越界 import | 写 dependency-cruiser/import-linter 规则 → 进 CI（fitness function） |
| 复杂度/重复超阈值 | 配 lint/sonar quality gate 阈值，新代码超标即 fail（baseline 容忍存量，学 Qodana） |
| 死代码 | knip/vulture 进 CI（先 baseline，禁新增） |
| 缺 license/SECURITY/分支保护 | 补文件 / 开分支保护 / 开 Dependabot |
| committed secret | gitleaks pre-commit + 轮换 + 清历史 |
| 架构/设计决策 | 写一条 **ADR**（MADR 格式，docs/adr/），记"为什么"，下次评审对照；可被 AI reviewer 当 PR 规则 |
| 复发的人为评审意见 | 转成 lint rule / Semgrep "copy the code you want to find" / Amp `.agents/checks` 独立 check |

> **关键**：只有"可机器检查"的结论才能固化成规则；纯判断性的写 ADR 留档。报告里把每条发现标"已可固化 / 仅留档"。

## 3. 落报告（finalize）

- 用 `report-template/report-template.md` 合成最终 markdown。
- 文件名：`<repo 名>-健康度报告.md`，落到**被评估仓库的根**（或用户指定目录）。同名冲突累加 `-2`/`-3`，不覆盖。
- 可选 HTML：按 `report-to-html` skill 规范内联生成单页（粘性目录 + hotspots 表 + 各层 pill + 折叠辩论历史），**不重新触发该 skill**。
- §metadata 记录：各层覆盖情况（自动/半自动/skip）、异构 verdict、辩论收敛、人类裁决、固化清单。

## 4. 自验（eval-first 闭环）

对照 Phase 0 冻结的成功标准清单逐条核对：每个"必答"问题都答了吗？没答的标"数据不足 + 为什么（工具 skip / 非 git / 窗口空）"。**不要假装全答**。

## 降级矩阵

| 场景 | 行为 |
|---|---|
| 探针部分 skip | 报告标该维度"未自动覆盖 + 安装指令"，不阻断 |
| cursor-agent 不可用 | 跳过异构，顶部 banner，软维度结论标高风险 |
| 非 git 仓库 | L2 不可用，明确告知；L0/L1/L3 照常 |
| 报告写盘失败 | inline 输出 + 标 write failed，绝不让主流程失败 |
