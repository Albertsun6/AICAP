# L3 — AI 语义评审 + 异构终审 + 多轮辩论 + 人类裁决

> 进入前 Read 本文件 + `prompts/L3-semantic-review.txt`，state "Loaded L3 + semantic prompt"。
> 用异构终审前再 Read `prompts/heterogeneous-final.txt` + `run-cursor-agent.sh`，state "Loaded heterogeneous review"。

## 为什么需要这层（探针管不到的）

"架构是否**合理**"、"目录**应不应该**这么分"、"这个解耦**到位没有**"、"历史教训这轮还在不在犯"——这些是**语义判断**，没有工具能输出客观 JSON。这正是 LLM 的强项，**也正是 LLM 共享盲区最危险的地方**：你既当裁判又当选手，单模型自评 = 循环自证（用户 CLAUDE.md ⑤）。所以 L3 = AI 评审 + **强制异构兜底**。

## 步骤

### 1. AI 语义评审（主 agent）
用 `prompts/L3-semantic-review.txt`，喂入：Phase 0 计划 + `probes.json`（L0-L2 客观数字）+ 仓库目录树 + top hotspots 的实际代码。产出对 4 个软维度的判断，**每条结论必须引具体文件/行**（不许泛泛"架构还行"）：
- **架构及框架合理性**：分层是否清晰？依赖方向是否合理（高层不依赖低层细节）？框架用法是否反模式？
- **目录结构合理性**：模块边界是否对应职责？有没有"杂物抽屉"目录？测试/源码/配置是否分明？
- **内容隔离/解耦**：跨模块耦合是否过紧？hotspots 是否暴露了"上帝模块"？（交叉 L1 instability + L2 hotspots）
- **历史评审教训**：查 ADR / 既有 lint rule / 本仓库过往评审产物（如有 HARDENING.md 类）——**上次定的规矩这次破了没？**

### 2. 异构终审（cursor-agent，强制）
把第 1 步的 L3 判断 + probes.json 摘要写进 `prompts/heterogeneous-final.txt`，经 `run-cursor-agent.sh` 跑 cursor-agent（GPT-5.5）独立 lens。它从不同模型视角挑：主 agent 有没有漏的架构问题？有没有把"风格偏好"当"架构缺陷"？有没有 over-claim？

调用方式（同 survey，4 硬点）：
- prompt 用 Write 工具生成到 `/tmp/ph-r1-prompt-<ts>.txt`（禁 heredoc）。
- `bash run-cursor-agent.sh <prompt> <out>`，Bash 工具 timeout=300000。
- exit code：0=Read 输出；69/65/66/124=降级（见 run-cursor-agent.sh 头注）。
- **cursor-agent 不可用 → 跳过异构，报告顶部 banner**："软维度仅经单模型评审，未异构审查；架构/解耦结论高风险，建议人工复核或装 cursor-agent 重跑"。**绝不**因此让主流程失败。

### 3. 主 agent 判断矩阵（4 档）
对 cursor-agent 每条意见表态（复用 `debate-review` 范式）：**accept / partial / defer / refute**（refute 必附 `reason: unsupported | contradicted`，contradicted 附文件行反证）。禁止"因为我不同意"就 refute、"因为权威"就 accept。

### 4. 多轮辩论 + 收敛
- 全 accept → 收敛，进 Phase 99。
- 有非 accept → cursor-agent rebuttal（Round 2，最多到 Round 3），规则同 survey Phase 6。
- 3 轮后仍分歧 → **AskUserQuestion 人类裁决**（每条 options：采纳主 agent / 采纳 cursor-agent / 独立判断）。人类即终审，不再回 cursor-agent。

## 输出

4 个软维度的结论（每条带证据 + 置信度 + 异构 verdict）+ 辩论矩阵（写进报告 §L3 + §辩论历史）。**分歧未裁决的条目不得在正文当定论**，放入"待人工确认"。
