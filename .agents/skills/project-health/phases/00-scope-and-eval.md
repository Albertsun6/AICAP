# Phase 0 — 界定范围 + eval-first

> 进入前 Read 本文件 + `eval/evaluations.md`，state "Loaded Phase 0 + evals"。

## 为什么先做这步

官方 Agent Skills best practices 的第一条：**"Create evaluations BEFORE writing extensive documentation"**。对应用户 CLAUDE.md ④——只有可验证的成功标准才约束 agent。健康度评估最容易翻车的方式是"跑一堆工具、打一堆分，但没人说得清这分意味着什么"。先冻结"怎样算健康"。

## 步骤

1. **确定目标仓库**：默认 cwd；用户指定则用指定路径。确认是 git work tree（`git rev-parse --is-inside-work-tree`）。非 git 仓库 → L2 hotspots 不可用，明确告知。

2. **检测技术栈**（决定哪些探针适用）：
   - `run-probes.sh` 会自动检测（package.json→js、pyproject/requirements/*.py→python、go.mod→go、pom/gradle→java、Cargo.toml→rust）。
   - 先跑一次 `bash probes/run-probes.sh --repo <repo> --out <outdir>` 看 `stack` 字段，再决定 L1 哪些维度能自动覆盖、哪些只能进 L3。

3. **冻结成功标准（eval-first）**：跟用户对齐或采用默认（来自 `rubric/thresholds.md`）。把"这次评估要回答什么"写成可验收的清单，例如：
   - 头号技术债 hotspot 是哪几个文件？（L2 必答）
   - 有没有 committed secret / 缺 license / 无分支保护？（L0 必答）
   - 死代码/重复率超阈值了吗？（L1，若工具可用）
   - 架构分层有没有被违反、有没有循环依赖？（L1 fitness + L3）
   - 目录结构是否合理、解耦是否到位？（L3 语义，必经异构）
   - **上一轮评审的教训这轮还在犯吗？**（流程，查 ADR / lint rule）

4. **声明覆盖边界**：哪些维度这次能自动量化、哪些靠 L3 主观 + 异构、哪些因工具缺失暂时 skip（带安装指令）。**不假装全自动**。

## 输出

一段"评估计划"：目标仓库 + 技术栈 + 本次成功标准清单 + 覆盖边界（自动/半自动/skip）。内存持有，作为 L0-L3 与 Phase 99 的验收靶子（同 survey 的 Brief 作用）。

## 反模式（禁止）

- 不跑探针先打分（违反"可执行优先"）。
- 把工具缺失的维度静默当"通过"（必须显式标 skip + 安装指令）。
- 用通用模板套所有仓库——阈值要按项目阶段调（活跃开发 vs 维护期，见 thresholds.md 的 lifecycle 注记）。
