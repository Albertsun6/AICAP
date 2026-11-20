---
name: survey
description: '针对任意话题，系统性地调研网上别人的做法、结构化比较方案、评估优劣、给出建议。 比 borrow-open-source 更通用——不限于开源代码，适用于任何选型、方案研究、最佳实践调查。 Use when the user says: "了解一下别人怎么做X" / "调研X方案" / "网上有哪些做X的方式" / "比较X和Y" "X的最佳实践" / "benchmark X" / "别人怎么解决X问题" / "/survey X" Phase 2 用 2 个 Claude agent + 2 个不同族的外部 lens（GPT 族与 Gemini 族，都经 cursor-agent 调用）四路并行异构搜索，发现取并集不投票；综合后 Phase 6 由 GPT 族主评审与 Grok 族红队第二评审（均经 cursor-agent）**并发**终审（红队 one-shot、条目并集 不投票），最多 3 轮辩论，剩余分歧里的事实争议交 Gemini（回避时 Grok）实查裁决、判断分歧 由人类裁决。族=训练实验室，换 CLI 不构成换族。对抗 Claude 训练数据集体盲区与 Claude↔GPT 回声室。某一族不可用时自动降级并在报告顶部 banner 提示——但用户不能主动跳过任何阶段。 Phase 1 遇 blocking unknown（研究对象/优先级/关键约束/排除范围拿不准）时先启动 多轮澄清提问（Phase 1.2，AskUserQuestion，≤3 轮）再冷冻 Brief；无 blocking unknown 零打扰。 /survey 的**质量门禁无 flag 可跳**（异构搜索/Reflection/Citation Health/异构终审都是硬约束）； 但**产物按消费者分三档**（A 内部输入=仅 md / B 给人阅读=+HTML+PDF / C 要听=+audio）， Claude 搜索路数按重要度分两档（重大决策 3 路 / 常规 2 路，异构两路任何档都不可省）。'
---
# /survey — 调研·比较·建议

## 工作流总览

```
Phase 1 问题界定
  → Phase 1.2 澄清提问（必要时，≤3 轮）      [blocking unknown → AskUserQuestion]
  → Phase 1.5 Brief                        [Read prompts/brief-template.txt]
  → Phase 2 (2 Claude + X1 gpt + X2 gemini   [Read prompts/agent-x.txt + agent-x2.txt]
             四路并行异构搜索，合并取并集)
  → Phase 2.5 Reflection Gate              [前提破裂 → 回问用户，换靶则回 Phase 1 重立 Brief（限 1 次）]
  → Phase 3-5 综合                          [生成报告]
  → Phase 5.5 Citation Health
  → Phase 6 异构终审：主评审(gpt 族·cursor)    [Read prompts/round1.txt]
             + 红队第二评审(grok 族·cursor, one-shot)  [Read prompts/round1-grok-prefix.txt]
             两个 async job 同回合并发，条目取并集
  → 多轮辩论（最多 3 轮，仅主评审参与）        [Read prompts/round{2,3}-rebuttal.txt]
  → 事实争议 tiebreaker(gemini 族/回避时 grok) [Read prompts/tiebreak.txt]
  → 剩余（判断类）分歧人类裁决
  → Finalize: 写报告 + HTML + PDF + audio×2 到 cwd  [Write <cwd>/<主题>-完整报告.md]
  → HTML report (step 4.5, after .md)          [Write <cwd>/<主题>-完整报告.html（交互式单页）]
  → PDF report (step 4.6, after .html)         [bash generate-pdf.sh -o <cwd>/<主题>-完整报告.pdf（Chrome headless 打印 HTML）]
  → Audio summary (step 5a)                    [bash generate-audio.sh -o <cwd>/<主题>-音频概要.m4a (脚本 -o 直写)]
  → Audio full (step 5b)                       [主 agent 写全文口语稿 → bash generate-audio.sh -t <口语稿> -o <cwd>/<主题>-完整音频.m4a]
```

**为什么默认就走异构 + 终审**：对抗 **Claude 训练数据集体盲区**——Claude 倾向把训练集里熟悉的工具/方法排在前面，可能漏掉训练截点后出现的新选项、非 Anthropic 生态的方案、低星但成熟的工业方案。3 个 Claude agent 并行只对抗"搜索范围偏差"，对抗不了模型层面共享的盲区。默认开启异构 = 默认假设你在用 /survey 调研对你重要的事情。**无 opt-out flag**——/survey 只有一条高质量路径。

**三族都走 Cursor（2026-11-19 起）**：`gpt` / `gemini` / `grok` 都经 `cursor-agent` 调用。搜索眼固定 `gpt`(X1) + `gemini`(X2)；Phase 6 主评审 `gpt`（异步 job）、红队第二评审 `grok`、事实裁判 `gemini`。**族 = 训练实验室，换 CLI 不构成换族**：`codex` CLI 是**可选备用通道**（默认流程、doctor 判定都不依赖它），它与 `gpt` 同族，所以绝不当红队或 tiebreaker。2026-09-09 曾因"OpenAI 将于 11-12 切断 Cursor"把 gpt 族迁去 codex；2026-11-19 实测 Cursor 侧 gpt 仍可用，遂迁回。**grok 不做搜索眼**——实测该族基础延迟高（263s 玩具 prompt），放进 Phase 2 会撞同步窗口。完整的替补链与选族规则见 `references/cursor-agent-invocation.md` §通道与族 / §三族分工与替补链。

**自动降级**：两只异构眼按族各自降级——一只挂了另一只继续；两只都不可用才退回 3 Claude（详见 `phases/02-research.md` §自动降级矩阵）。三族共用 Cursor 一套凭据，Cursor 登录失效时三族同灭；额度见底（68）按族处理。Phase 6 主评审按 `gpt → grok → gemini` 替补链换族重试；红队挂了**不阻断**（增量意见不是质量门禁）。用户无法主动选择跳过任何阶段。**降级只通知、不提问**：doctor 非 0 或通道中途失效时，用一句话告知用户降级情况和修复命令（如需用户本人登录），**不发 AskUserQuestion、不等回复**，照降级矩阵继续跑（2026-11-20 加：两次实跑都因为停下来问而白等 17 min 和 3 min）。降级原因是用户能自己修的（如登录失效），进入 Phase 6 前重跑一次 `doctor.sh`：用户已修好就恢复该通道参加终审；仍未修好则照降级走，报告顶部 banner 照常标明，不算完整通过异构门禁。

**异构自检前置**：Phase 2 启动 X1/X2 前先跑 `bash doctor.sh`（秒级，不耗配额）——文件/执行位/cursor-agent 的安装与登录（用 `--list-models` 实打服务端，不信 CLI 自述：过期凭据下 `cursor-agent status` 照样自称 Logged in）/三 lens 模型解析（模型列表临时缩水时会明说"疑似缩水，稍后重试"，不判该族下架）/模型排名（L3.2：汇总 `NEW-MODEL:` 与排名文件自检的提示、核对日期是否超过 60 天；只报 WARN，不改 verdict）/额度留痕（读真调用留下的痕迹——额度见底时快检全绿，只有真调用会撞）逐层检查，执行位问题当场自动修复，其余给出确切修复命令；非 0 verdict 时**提前**告知用户即将发生的降级，而不是等中途 banner。**grok 族死只报 WARN 不降 verdict**（它只是替补 + 红队，不是搜索眼）；codex 备用通道未装/未登录只打一行 INFO，同样不影响 verdict。详见 `references/cursor-agent-invocation.md` §自检 + 自修复。

---

## Prompt Template Read Gate（硬约束，不可绕过）

> **背景**：[anthropics/skills issue #591](https://github.com/anthropics/skills/issues/591) 指出长对话中 skill instructions 会衰减——LLM 容易凭模糊记忆"演"prompt 模板内容。/survey 把 prompt 模板抽到 `prompts/*.txt`，**必须强制 Read** 才能保证质量门禁。

进入以下阶段**前**，主 agent 必须 Read 对应 prompt 文件（禁止凭记忆重建）：

| 阶段 | 必读 prompt 文件 | 强制 gate 语句 |
|---|---|---|
| Phase 1.5 Brief | `prompts/brief-template.txt` | `Read brief-template.txt; state "Loaded Brief template"` |
| Phase 2 Agent X1 | `prompts/agent-x.txt` | `Read agent-x.txt; state "Loaded Agent X1 prompt"` |
| Phase 2 Agent X2 | `prompts/agent-x2.txt` | `Read agent-x2.txt; state "Loaded Agent X2 prompt"` |
| Phase 6 Round 1 主评审 | `prompts/round1.txt` | `Read round1.txt; state "Loaded Round 1 prompt"` |
| Phase 6 Round 1 红队 | `prompts/round1-grok-prefix.txt`（拼在 round1.txt 之前） | `Read round1-grok-prefix.txt; state "Loaded red-team prefix"` |
| Phase 6 Round 2 | `prompts/round2-rebuttal.txt` | `Read round2-rebuttal.txt; state "Loaded Round 2 prompt"` |
| Phase 6 事实 tiebreaker | `prompts/tiebreak.txt` | `Read tiebreak.txt; state "Loaded tiebreak prompt"` |

**模板缺失处理**：如果文件不存在或 Read 失败，**停止该阶段**并报告错误；不允许"演"模板内容继续。

---

## Phase Read Gate（硬约束，不可绕过）

每个 Phase 启动**前**必须 Read 对应 phase 文件（不要凭整体印象"演"流程）：

| Phase | 必读 phase 文件 | 强制 gate 语句 |
|---|---|---|
| 1 + 1.2 + 1.5 | `phases/01-question-framing.md` | `Read phases/01-question-framing.md; state "Loaded Phase 1+1.2+1.5"` |
| 2 | `phases/02-research.md` + X1/X2 prompts | `Read phases/02-research.md; state "Loaded Phase 2"` |
| 2.5 | `phases/03-reflection.md` + `references/source-quality.md` | `Read both; state "Loaded Phase 2.5 + Source Quality"` |
| 3-5 + Audio | `phases/04-synthesis.md` | `Read phases/04-synthesis.md; state "Loaded Phase 3-5 + Audio spec"` |
| 5.5 | `phases/05-citation.md` | `Read phases/05-citation.md; state "Loaded Phase 5.5"` |
| 6 | `phases/06-debate.md` + Round 1 + 红队 prefix + Round 2 + tiebreak prompts | `Read phases/06-debate.md + round prompts; state "Loaded Phase 6"` |

**为什么 SKILL.md 不能太薄**：以下硬性 invariants 必须保留在 SKILL.md 内（不光放 phase 文件）：
- 异构搜索强制（Phase 2 必须 ≥2 Claude + 2 个**不同族**外部 lens：X1=GPT 族、X2=Gemini 族，均经 cursor-agent；一只挂了另一只继续。**异构两路任何档位不可省**）
- **族 = 训练实验室，换通道不构成换族**：codex CLI 的 gpt-6 与 cursor 的 gpt-5.6 同属 OpenAI；主评审、红队、tiebreaker 三个席位必须异族，备用通道 codex 与 gpt 同族，绝不当红队或 tiebreaker（同族自审自签）。任何新通道接进来时必须复用底层实验室已有的族标签，不得因为换了 CLI 就新造一个族
- **澄清按需、不滥用**（Phase 1.2）：blocking unknown 按**合取门槛**认定（实质分叉可写出 + 推不出 + 无安全默认/条件化覆盖 + 猜错大返工），认定了必须问、不许默默猜；无则零打扰。未知入显式队列，每轮攒齐一次问（AskUserQuestion ≤4 问带选项）、最多 3 轮；**任何终止路径都把剩余未知转显式假设**（进 Brief「初始假设」）；答案冷冻进 Brief 注入下游；非交互/用户不答 → 显式假设 + metadata 披露，不阻塞
- **Brief 冷冻后改靶必经用户**：任何阶段（Phase 2.5 前提破裂、Phase 6 辩论中 reviewer 的前提类建议）发现研究前提不成立，一律回问用户（按原题继续+标注风险 / 换靶重立 Brief，换靶限 1 次），不许自行改研究问题——两个 AI 一致也不算用户同意
- **产物分档 ≠ 门禁分档**：产物可按消费者收敛（A/B/C 三档），但 Phase 1-6 的质量门禁一律照跑
- **全流程不做多数投票**：发现阶段取并集，终审靠辩论，事实争议靠实查，判断归人类。**双评审也不投票**——主评审与红队意见相左时两条都进判断矩阵各自表态，谁也不因"另一位没提"被降权
- Phase 6 多轮辩论 + 人类裁决强制（高质量 only，无 opt-out）
- **红队是增量不是门禁**：Round 1 红队（grok，one-shot）挂了不阻断 Phase 6，标 metadata 即可；但**主评审与 tiebreaker 必须异族**这条是硬的，绝不允许同族自审自签
- 任一族或 cursor-agent 整体不可用时自动降级 + banner（fallback contract）
- **模型排名要查证，但不占调研关键路径**：三族选哪个模型由 `model-ranking.conf` 决定（上网查证后的顺序 + 已核实清单 + 依据 URL + 核对日期）。出现 `NEW-MODEL:` 行（实时列表里有清单之外的模型，含选型规则不收的形态：裸 id / 只有 `-max` 或低档 / `-preview` / 认不出的命名）或 `WARN: … 排名文件 …` 行时，**本次调研不停下来核实**：照当前解析结果继续跑，报告 §metadata 写 `模型排名: 未核实（检测到 <名字>，交付后单独核实）`；提示行写着「本次已选用」时（未核实的新模型被选中参与了本次调研），§metadata 还要写明哪一席用了它，读者据此判断可信度。报告交付后，主 agent 把核实作为**独立任务**提给用户（有新开会话的工具就开一个待启动的会话，没有就在最终回复里单列一行待办，写清提示行原文）——在那个任务里查官方模型页和厂商发布说明（有独立评测一并查），更新排名文件的顺序、清单、依据 URL 和核对日期，跑 `bash test-model-selection.sh`（约 4 min）。doctor 报核对日期超过 60 天时同样处理（2026-11-20 改：原来要求先核实再继续，查证 + 测试会给调研加 10–30 min）。**去哪看**：`doctor.sh` 的 L3.2 一节（**exit 0 / HEALTHY 也要看**，这类提示不改 verdict）；同步调用 runner 的 stderr；异步 job 的 `status` / `wait` 输出里状态行下面缩进的行。**改哪一份**：`.rulesync/skills/survey/model-ranking.conf`（源），改完在仓库根跑 `pnpm run ai:generate` 并给镜像里的 `.sh` 补执行位——直接改 `.claude/skills/survey/` 下的镜像会在下次生成时被覆盖（doctor 的修复建议会给出源文件路径）。通道不通或查不到时不许装作查过：照当前解析结果继续。报告 §metadata 的 `模型排名:` 字段必填：`已核实 <核对日期>` 或 `未核实（<原因>）`。**盲区**：名字里不含族名的新模型（如 OpenAI 的 `o5`）脚本检测不到，靠 60 天复查时对照实时列表全量看一遍
- 信源排除（不搜中文社区）
- 每个 phase / prompt 进入前的强制 Read gate

---

## 文件结构

```
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/
├── SKILL.md                       # 本文件：索引 + 硬 invariants + Read gate
├── phases/
│   ├── 01-question-framing.md     # Phase 1 + 1.5 Brief
│   ├── 02-research.md             # Phase 2 四路异构搜索 + 并集合并 + 降级矩阵 + 调用
│   ├── 03-reflection.md           # Phase 2.5 Reflection Gate
│   ├── 04-synthesis.md            # Phase 3-5 综合 + 报告 + Audio overview
│   ├── 05-citation.md             # Phase 5.5 Citation Health Layer A + B
│   └── 06-debate.md               # Phase 6 多轮辩论 + 人类裁决
├── references/
│   ├── source-quality.md          # Source Quality Helper（被 Phase 2/2.5/5.5/6 共用）
│   └── cursor-agent-invocation.md # 三族经 cursor-agent（+ 可选备用通道 codex）的族/通道定义 + 调度 4 硬点 + 模型选择 + exit code（被 Phase 2/6 共用）
├── lib/
│   └── agent-common.sh            # 两个 runner 的共享底座：watchdog / 进程树屠杀 / 额度留痕 / 段落校验（带版本护栏）
├── prompts/
│   ├── brief-template.txt         # Phase 1.5 Brief 模板
│   ├── agent-x.txt                # Phase 2 Agent X1 模板（gpt 族经 cursor·查 Claude 盲区）
│   ├── agent-x2.txt               # Phase 2 Agent X2 模板（gemini 族经 cursor·查 Claude+GPT 共同盲区）
│   ├── round1.txt                 # Phase 6 Round 1 主评审 prompt（默认 gpt 族经 cursor，替补族用同一份·7 个常规评审角度）
│   ├── round1-grok-prefix.txt     # Phase 6 Round 1 红队 prefix（grok 族·4 个红队角度，拼在 round1.txt 前）
│   ├── round2-rebuttal.txt        # Phase 6 Round 2 rebuttal prompt
│   └── tiebreak.txt               # Phase 6 事实核查 tiebreaker prompt（gemini 族，回避时 grok）
├── check-citations.sh             # Phase 5.5 Layer A 脚本
├── run-codex.sh                   # 可选备用通道 codex CLI（与 gpt 同族；默认流程不用）；--auth-check 供 doctor 报备用通道状态
├── run-cursor-agent.sh            # cursor-agent 通道（gpt / gemini / grok）；模型运行时自动解析，--resolve-only 供 doctor 复用
├── run-agent-async.sh             # 重活异步 job（nohup 脱离 600s 窗口；按族路由到上面两个 runner；X1 与 Phase 6 评审必走这里）
├── doctor.sh                      # 异构链路自检+自修复（Phase 2 前必跑快检；--probe 加端到端探针）
├── test-model-selection.sh        # cursor 侧模型选择逻辑 + runner 契约的可执行断言（Cursor 改命名时先跑这个）
├── fixtures/                      # test-model-selection.sh 的夹具：模型列表（完整列表 + 临时缩水形态）+ 测试用排名文件
├── model-ranking.conf             # 三族的模型排名：系列强弱顺序 + 已核实清单 + 依据 URL + 核对日期（出现 NEW-MODEL 时先查证再改它）
├── test-run-codex.sh              # codex runner + lib 的可执行断言（codex CLI 升级时先跑这个）
├── generate-audio.sh              # Audio 主脚本 (edge-tts/say；-o OUT；-t 传口语稿=完整音频模式)
├── generate-audio-openai.sh       # Audio 可选 fallback (OpenAI TTS，支持 -o OUT)
└── generate-pdf.sh                # PDF 生成 (Chrome headless 打印 step 4.5 的 HTML；无 Chrome 则 skipped)
```

---

## 触发与标志

**触发**（用户任意说以下内容均可）：
- "了解一下别人怎么做X"
- "调研X方案 / 调研一下X"
- "比较X和Y / X和Y哪个好"
- "X的最佳实践是什么"
- "benchmark X"
- "/survey X"

**行为**：始终走全流程（Phase 1 → 1.2（必要时）→ 1.5 → 2 → 2.5 → 3-5 → 5.5 → 6 多轮辩论 + 人类裁决）。**质量门禁无 flag 可跳**——异构搜索、Reflection、Citation Health、异构终审都是硬约束。

---

## 输出分档（2026-07-31 加：按消费者定产物，不按心情简化）

**质量门禁不分档，产物分档**。判据是**这份报告的消费者是谁**：

| 档 | 判据 | 产物 | 典型场景 |
|---|---|---|---|
| **A 内部输入** | 产出直接喂给流程/设计/决策，**不给人阅读** | **仅 `.md`** | 调研结论要用来改某份设计文档/写 skill/定技术选型 |
| **B 给人阅读** | 用户要看、要留档、要发同事 | md + HTML + PDF | 用户明确说"我要看"、或调研本身就是交付物 |
| **C 要听/要演示** | 通勤听、给客户放、培训用 | 再加 audio×2 | 用户明说要音频/要演示 |

**默认 B**。以下情况**直接走 A**（不必问用户）：
- 用户在一个正在进行的开发/设计任务中途要求调研，且明说了调研用途是改某个文件/做某个决策
- 调研主题是内部技术细节（如"某 API 怎么用""某算法怎么选"）

**升档**：用户随时可说"这个转 HTML / 加音频"，几分钟内补出（HTML ~1min、PDF ~10s；**audio 最贵：概要 ~16min、完整 ~25min 纯合成**）。

**A 档的报告写法也要收敛**：只写「结论 / 改哪里 / 证据账本 / 待验证」，不写逐子问题详述（目标 ≤80 行）。逐子问题的详细内容留在 subagent 的 Compressed Findings 里，需要时再展开。

---

## 提速要点（2026-07-31 加）

耗时结构（2026-11-19 更新；三族迁到 Cursor 后**端到端总耗时未实测**，有实测的分段写明日期，其余标「未实测」）：四路搜索并行、等最慢的一路——X1 gpt high 档 2026-11-19 实测一次约 4 min（只测过这一次，上限未实测；deadline 900s），X2 的 Gemini 4 Neon high 档未实测。写报告 ~5min（旧估计）。Phase 6 Round 1：主评审 gpt xhigh 经 cursor 2026-11-19 实测 5–10 min；grok 红队 high 档未实测，有**软 deadline 900s**，主评审回来后最多再等 15 min，不再无上限等它。每追加一轮辩论 +3–8min（R2/R3 降 high；经 cursor 未实测，沿用旧估计）、中途协调 ~4min（旧估计）。**快路径（Round 1 直接收敛）目标 ≤20min，未实测；慢路径不承诺**——标题里原来的"实测 20 分钟 → 目标 ≤12 分钟"与旧账"Phase 6 ~5min / 总 12min"都写于红队接入前，已作废。start 异步 job 后向用户报预计耗时，以 `references/cursor-agent-invocation.md` §异步 job 第 1 步的口径为准。

1. **搜索路数按重要度分档**：
   - **重大决策**（会改架构/宪法/对外承诺）：五路（Claude×3 + 异构×2）
   - **常规调研**（选型、最佳实践）：四路（Claude×2 + 异构×2）——异构两路不可省，这是 skill 的立身之本
   - **轻量核实**（某个事实/某个版本行为）：**不要用 /survey**，直接 WebSearch/WebFetch
2. **Phase 6 终审在报告初稿落盘后立刻发起**，不等中途汇报——终审跑的这几分钟可以同时做别的事
3. **减少中途汇报**：各路返回时**不逐路汇报**，全齐后一次性给用户「并集要点 + 分歧点」。逐路汇报本身要花 3-4 分钟
4. **A 档报告不写详述**：见上方分档表
5. **finalize 只做本档要求的产物**：A 档跳过步骤 4.5/4.6/5/6（HTML/PDF/audio），metadata 相应字段写 `skipped (档位 A)`
6. **模型/档位路由（2026-09-10 加）**：主模型（及其全局 xhigh 档）**只做需要判断的活**；检索型与产出型任务一律下放。此前所有 Claude 子 agent 都继承主模型最高档去做搜索和转 HTML，是最大的 token 与时间浪费点

   | 任务 | 执行者 | 模型 / 档位 | 为什么 |
   |---|---|---|---|
   | Phase 1 界定 / 澄清 / Brief | 主 agent | 主模型 | 判断 |
   | Phase 2 Agent A / B（/ C） | Agent 工具子 agent | **sonnet** | 检索型 |
   | Phase 2 X1 | cursor gpt（异步） | **high** | 2026-11-19 实测一次联网搜索约 4 min；xhigh 不值 |
   | Phase 2 X2 | cursor gemini | **high** | 检索型 |
   | Phase 2.5 检查清单 | 主 agent | 主模型 | 判断 |
   | Phase 2.5 追搜 | cursor gemini 同步 / sonnet 子 agent | prompt 限「最多 15 次查询」 | 定向补搜，串行门 |
   | Phase 3–5 综合、写报告 | 主 agent | 主模型 | 核心判断 |
   | Phase 5.5 Citation | 脚本 + 主 agent 抽样 | — | — |
   | Phase 6 R1 主评审 | cursor gpt（异步） | **xhigh** | 全管线最难推理；2026-11-19 实测全文评审 5–10 min |
   | Phase 6 R1 红队 | cursor grok | **high** + 软 deadline 900s | 增量意见，联网取证不靠推理深度 |
   | Phase 6 R2 / R3 rebuttal | cursor gpt（与 R1 同版本同系列） | **high** | 只看非 accept 条目，范围窄 |
   | Phase 6 判断矩阵 / 人类裁决 | 主 agent | 主模型 | 判断 |
   | tiebreaker | cursor gemini | **high** | 事实核查 |
   | HTML（B/C 档） | **sonnet** 子 agent | 按 phases/04 第 4.5 步的特性清单 | 产出型，几十 KB 输出 |
   | PDF / 音频合成 | 脚本 | — | — |
   | 完整音频口语稿（C 档） | **sonnet** 子 agent | 6k–12k 字 | 产出型 |

   三族的档位都由 `SURVEY_CURSOR_EFFORT=high|xhigh` 控制（逐条命令前缀设置，不要 export），Claude 子 agent 由 Agent 工具 `model=` 参数控制。**不动的两处**：X1 与 R1 决定召回与评审深度，降档等于降质量。

7. **五路一条消息发出（2026-11-20 加）**：先 Write 好 X1/X2 两份 prompt，再在**同一条消息**里发 Agent A/B（/C）+ X1 `start` + X2 `start`（X2 也走异步 job），然后后台 `wait`。11-19 实跑 X1/X2 比 Claude 路晚发 4 min，白等
8. **核实交给子 agent，改稿攒齐一次改（2026-11-20 加）**：Phase 5.5 Layer B 与 Phase 6 核对 reviewer 事实，取原文都打包给**一个** haiku 子 agent（只摘不判，判定仍归主 agent）；主 agent 不自己逐条 WebFetch。改初稿时把要改的地方攒齐后一次 Write，不逐条 Edit。11-12 实跑主 agent 自己核对 + 18 次逐条 Edit 用了约 8 min
9. **子 agent 不为提速而减（2026-11-20 实测）**：各路搜索并行，Claude 路 1–3 min、不在关键路径上，少一路几乎不省时间。三次实跑里每一路都在最终报告里贡献了别人没找到的引用（Claude 每路 2–16 条、X1 1–7 条、X2 1–10 条，各路重叠很小），红队每次贡献 5–7 条被采纳的独有意见。减路数只省 token，代价是丢引用
10. **每路搜索有预算、会提前停（2026-11-20 加，借鉴 Anthropic / OpenAI deep-research）**：每路约 10 次、最多 15 次查询，覆盖完或饱和就停，并交代停止理由，见 `phases/02-research.md` §搜索预算与停止条件
11. **搜索结果带原文引句（2026-11-20 加，借鉴 199-bio / Firecrawl）**：Phase 5.5 对非决策关键、带引句的 claim 直接判档，每路抽 1/3 回抓核对；一条不符整路重抓；支撑 §推荐 的 claim 一律回抓，见 `phases/05-citation.md` Layer B
12. **先到先处理，结论等齐再下（2026-11-20 加）**：等外部两路时只做去重、检查清单、来源账本这类机械活；方案描述、§推荐、评分、追搜决策必须等所有路并入，见 `phases/02-research.md` §并发协调
13. **终审只辩影响结论的分歧（2026-11-20 加）**：reviewer 与主 agent 各标一次，任一方说「影响」就算；不影响的不进 Round 2/3，但事实性的照送 tiebreaker、判断性的照交人类裁决，见 `phases/06-debate.md` §影响结论标记

---

## 边界（不做的事）

- **不写代码**：survey 只做研究，实施交给其他 skill 或用户
- **不无限抓取**：每个来源最多 fetch 2 页，保持聚焦
- **不强制有答案**：数据不足时明确说"数据不足，建议验证"，不填空分

## 输出文件位置（finalize 时强制）

- **最终报告 + HTML + PDF + audio×2 → cwd**（用户启动 Claude Code 时所在目录）
  - 报告：`<主题>-完整报告.md`（主题由主 agent 从研究问题提取 8-15 字中文 / 英文短语）
  - HTML：`<主题>-完整报告.html`（交互式单页，含粘性目录 / Mermaid 图 / 置信度 pill，双击即开）
  - PDF：`<主题>-完整报告.pdf`（Chrome headless 打印 HTML；无 Chrome → metadata 标 skipped，不阻断）
  - Audio 概要：`<主题>-音频概要.m4a`（§推荐+风险摘要，约 10 分钟）
  - Audio 完整：`<主题>-完整音频.m4a`（主 agent 全文口语稿改写后朗读，约 30-50 分钟）
  - 同名冲突：`.md` / `.html` / `.pdf` / 两个 `.m4a` 五者同步累加 `-2` `-3` 后缀（不覆盖旧文件、不询问）
- **中间产物 → /tmp**：agent prompt 文件（`/tmp/survey-{x1,x2,r1,r2,r3,tb}-prompt-<ts>.txt`，前缀不许重名否则并发互相覆盖）、对应输出、Citation health JSON 全部留 /tmp，不污染 cwd
- 详细 finalize 流程见 `phases/04-synthesis.md` §Finalize 输出步骤

---

## 与相关 Skill 的区别

| Skill | 适用场景 |
|---|---|
| `/survey` | 任意话题调研，通用，重研究+比较+建议 |
| `/borrow-open-source` | 专门研究开源代码，目标是借鉴到自己的项目 |
| `/harness-review-workflow` | 你已有方案/设计，需要多 AI 评审 |

---

## 借鉴来源（设计参考，非执行步骤）

- **Brief as north star**（Phase 1.5）：LangChain Open Deep Research `write_research_brief` 节点
- **Compressed Findings + Source Inventory 二段式**（Phase 2 #5）：LangChain ODR `compress_research`；Anthropic 工程 blog (2025-06-13) "isolated context windows is biggest single win"
- **Source Quality 启发式评分**（#8）：Tavily / Exa source signal；DeepResearch Bench unique-domain count
- **Reflection Gate**（Phase 2.5 #3）：LangChain ODR `think_tool` / Local Deep Researcher `reflect_on_summary` / Self-RAG 反射 token (arxiv 2310.11511)
- **Citation Health Layer A + B**（Phase 5.5 #4）：DeepResearch Bench FACT framework / arxiv 2604.03173（URL hallucination）/ arxiv 2605.06635（cited but not verified）/ CiteAudit
- **异构多轮辩论 + 人类裁决**（Phase 6）：Heterogeneous Multi-Agent Debate (KSU JCIS 2025) / Multi-Agent Debate (Du et al. arxiv 2305.14325) / Anthropic Skills issue #591 long-conversation instruction decay
- **Audio summary**（Phase 6 finalize 后）：灵感来自 Gemini Deep Research / NotebookLM；当前实现是 §推荐 段摘要朗读 v0，下一步可能升级为单人 podcast-host 风格

---

## Troubleshooting / FAQ

**为何三族都走 cursor-agent，而不是直接调 API**：走用户已有的 Cursor 订阅，零 API key、一套登录。代价是三族共用一套凭据，Cursor 登录失效时三族同灭（届时退 3 Claude）；额度是否按族分开未实测，撞 68 按族降级。codex CLI（ChatGPT 订阅）保留为可选备用通道：gpt 族在 Cursor 不可用时可手动用 `run-agent-async.sh start … codex` 顶上，需自行 `codex login`。

**Audio 在非 macOS 上怎么办**：`generate-audio.sh` 自动检测，非 macOS 直接 skipped。若 `OPENAI_API_KEY` 已 export，主 agent 调度 `generate-audio-openai.sh` 作为可选 fallback。
