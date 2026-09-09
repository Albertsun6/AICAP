# L3 — AI 语义评审 + 异构终审 + 多轮辩论 + 人类裁决

> 进入前 Read 本文件 + `prompts/L3-semantic-review.txt`，state "Loaded L3 + semantic prompt"。
> 用异构终审前再 Read `prompts/heterogeneous-final.txt` + survey 的 `references/cursor-agent-invocation.md`（路径 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/references/`），state "Loaded heterogeneous review"。

## 为什么需要这层（探针管不到的）

"架构是否**合理**"、"目录**应不应该**这么分"、"这个解耦**到位没有**"、"历史教训这轮还在不在犯"——这些是**语义判断**，没有工具能输出客观 JSON。这正是 LLM 的强项，**也正是 LLM 共享盲区最危险的地方**：你既当裁判又当选手，单模型自评 = 循环自证（用户 CLAUDE.md ⑤）。所以 L3 = AI 评审 + **强制异构兜底**。

## 步骤

### 1. AI 语义评审（主 agent）
用 `prompts/L3-semantic-review.txt`，喂入：Phase 0 计划 + `probes.json`（L0-L2 客观数字）+ 仓库目录树 + top hotspots 的实际代码。产出对 4 个软维度的判断，**每条结论必须引具体文件/行**（不许泛泛"架构还行"）：
- **架构及框架合理性**：分层是否清晰？依赖方向是否合理（高层不依赖低层细节）？框架用法是否反模式？
- **目录结构合理性**：模块边界是否对应职责？有没有"杂物抽屉"目录？测试/源码/配置是否分明？
- **内容隔离/解耦**：跨模块耦合是否过紧？hotspots 是否暴露了"上帝模块"？（交叉 L1 instability + L2 hotspots）
- **历史评审教训**：查 ADR / 既有 lint rule / 本仓库过往评审产物（如有 HARDENING.md 类）——**上次定的规矩这次破了没？**

### 2. 异构终审（外部 GPT 族 lens，强制）
把第 1 步的 L3 判断 + probes.json 摘要写进 `prompts/heterogeneous-final.txt`，经 **survey 的 runner** 跑 codex（GPT 族，ChatGPT 订阅）独立 lens。它从不同模型视角挑：主 agent 有没有漏的架构问题？有没有把"风格偏好"当"架构缺陷"？有没有 over-claim？

**本 skill 不自带 runner**（2026-09-09 删掉了那份陈旧分叉：它超时依赖本机没有的 `timeout` 命令、无 auth/quota 分类、撞额度不留痕，让 survey 的 doctor 事后仍报绿灯）。直接复用 survey 的脚本，路径 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/`：

- **先跑自检**：`bash <survey>/doctor.sh`（秒级、零配额）。非 HEALTHY 时**提前**告知用户异构评审会降级，不要等调用失败才用 banner 揭晓
- prompt 用 Write 工具生成到 `/tmp/ph-r1-prompt-<ts>-<随机>.txt`（禁 heredoc）
- **异步调用**（全文评审在 xhigh 档常要 3–15 分钟，同步 600s 窗口装不下）：
  `SURVEY_REQUIRE_SECTIONS='Verdict' bash <survey>/run-agent-async.sh start <prompt> <out> codex 1800` → 拿 JOB_DIR → `Bash(run_in_background:true)` 跑 `bash <survey>/run-agent-async.sh wait <job-dir> 540`；到点未完就报进度再续一波（⑥.5 后台长任务纪律）
- exit code（与 survey 同一张表）：`0`=Read 输出；`67` 认证失效（让用户 `codex login`，不重试）；`68` 用量耗尽；`69` 未安装；`124` 超时；`65`/`66` 调用失败/空输出——**非 0 一律降级**，理由按 code 如实写进 banner
- codex 不可用 → 按 survey 的替补链换 `grok`（cursor 通道）重试 1 次：`... start <prompt> <out> grok 1800`；仍失败 → 跳过异构，报告顶部 banner："软维度仅经单模型评审，未异构审查；架构/解耦结论高风险，建议人工复核或修复 codex/cursor-agent 后重跑"。**绝不**因此让主流程失败

### 3. 主 agent 判断矩阵（4 档）
对异构 lens 每条意见表态（复用 `debate-review` 范式）：**accept / partial / defer / refute**（refute 必附 `reason: unsupported | contradicted`，contradicted 附文件行反证）。禁止"因为我不同意"就 refute、"因为权威"就 accept。

### 4. 多轮辩论 + 收敛
- 全 accept → 收敛，进 Phase 99。
- 有非 accept → 异构 lens rebuttal（Round 2，最多到 Round 3；同一 job 方式，`SURVEY_CODEX_MODEL=<R1 实际 id>` 复用同一评审者），规则同 survey Phase 6。
- 3 轮后仍分歧 → **AskUserQuestion 人类裁决**（每条 options：采纳主 agent / 采纳异构 lens / 独立判断）。人类即终审，不再回外部模型。

## 输出

4 个软维度的结论（每条带证据 + 置信度 + 异构 verdict）+ 辩论矩阵（写进报告 §L3 + §辩论历史）。**分歧未裁决的条目不得在正文当定论**，放入"待人工确认"。报告 metadata 记录实际用的模型 id（runner 的 `MODEL:` 行），不许凭记忆写。
