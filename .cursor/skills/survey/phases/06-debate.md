# Phase 6：异构终审 + 多轮辩论

**始终执行**：外部 lens 异构终审（主评审 codex/GPT 族 + 红队 cursor/grok 族）+ 主 agent 判断矩阵 + 最多 3 轮辩论 + 剩余分歧人类裁决。**无 opt-out**——/survey 是高质量调研 skill，Phase 6 是质量门禁不是可选项。

> **`finalize` 语义统一定义**：本文档所有 `finalize` 指代 → 进入 [`phases/04-synthesis.md`](04-synthesis.md) §Finalize 输出步骤（写 cwd 报告 + audio）。**只有** Phase 6 收敛（合法路径 5 条：Round 1 全 accept / Round 2/3 双方同档 / tiebreaker 裁清全部剩余分歧 / 人类裁决完成 / Phase 6 整段被跳过且已打 SKIPPED banner）后才允许触发 finalize；之前任何 round 的中间矩阵 / rebuttal 都**禁止**写 cwd 文件。

两只异构眼都不可用时整段 Phase 6 跳过 + 顶部 banner（见 `../phases/02-research.md` §自动降级矩阵）。

## 设计原则

外部主评审的终审是**独立 lens 的意见**，不是"权威修订指令"。主 agent 必须对每条建议表态；剩余分歧由人类裁决而非 AI 共识收敛——防止 Claude 与 GPT 共享盲区时的"AI 回声室"。

**红队第二评审（grok，2026-08-15 加）也不是第三票**：它存在的理由恰恰是"报告作者是 Claude、主评审是 GPT，这两家最可能一起觉得没问题"。所以——
- 两位 reviewer 意见相左时**不投票、不取交集**：两边的条目**并集**进判断矩阵，主 agent 逐条四档表态
- 红队是**增量意见不是质量门禁**：它挂了不阻断 Phase 6（主评审那份照走），标 metadata 即可
- 红队 **one-shot**：只出 Round 1，不进 Round 2/3 rebuttal。它的非 accept 条目直接进第 7 步分类

**tiebreaker 模型（默认 gemini）同样不改变这条原则**：它只被允许裁决**可核查的事实**，且必须附证据 URL；一切判断类分歧仍然只归人类。**本 skill 任何环节都不做多数投票**——发现阶段取并集，终审阶段靠辩论 + 人类裁决，事实争议靠实查。理由见 `02-research.md` §合并规则。

## 工作流（线性 8 步）

1. **Round 1（双评审并发）**：主评审（`gpt` 族，codex）+ 红队第二评审（`grok` 族，one-shot）**同一回合各发一个 async job** → 两份 verdict（红队有 **900s 软 deadline**，迟到不阻断，见 §Round 1）
   - 两份都 Concur → 写最小 metadata，结束
   - 任一 Refine / Dissent → 主 agent 对**两份条目的并集**做 4 档判断矩阵
2. **收敛检查 1**：全 accept → finalize；否则进 Round 2
3. **Round 2**：主评审 rebuttal 非 accept 条目 → 主 agent 二轮判断（维持原档 OR 让步并改档，必附论据）。**红队条目不进本轮**（one-shot），它的非 accept 条目原样挂着等第 7 步
4. **收敛检查 2**：双方同档（无分歧）→ finalize；否则进 Round 3
5. **Round 3**：主评审二次 rebuttal → 主 agent 三轮判断（同 Round 2 规则）
6. **收敛检查 3**：双方同档 → finalize；仍分歧（含红队挂着的非 accept 条目）→ 进第 7 步
7. **事实核查 tiebreaker**（族按 helper §三族分工 的选族规则定，默认 `gemini`，1 次调用）：把剩余分歧分成**事实性**与**判断性**；事实性的交裁判模型实查裁决，判断性的直接进第 8 步
8. **人类裁决**：AskUserQuestion 暴露**剩下的**分歧（判断性分歧 + tiebreaker 判 `UNRESOLVED` 的），>4 条分批 ≤4，每条 options = 采纳主 agent / 采纳 reviewer（**注明是主评审还是红队**）/ 独立判断；用户最终立场 → finalize（不再回 cursor-agent）

## Round 1：异构终审（主评审 + 红队第二评审，并发）

> **提速（2026-07-31 加）**：Round 1 应在**报告初稿落盘后立刻发起**（`run_in_background: true`），不要先跟用户逐条汇报再发——终审跑的这几分钟里主 agent 可以做别的事（如同步更新下游文档、准备修订清单）。实测这一条能省 3-4 分钟。

**输入**：Phase 5 完整报告 markdown

**prompt 模板路径**：
- 主评审：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/round1.txt`
- 红队：`prompts/round1-grok-prefix.txt` **拼在** `round1.txt` **全文之前**（红队要知道主评审在查什么，才能避开重复；两个文件都必须 Read，不许凭记忆拼）

**调度**：

| | 主评审 | 红队第二评审 |
|---|---|---|
| family / 通道 | `codex`（GPT 族；替补链 `codex → grok → gemini`） | `grok`（cursor；主评审已降到 grok 时**取消本路**） |
| 文件前缀 | `survey-r1-` | `survey-r1g-` |
| 调用方式 | `SURVEY_REQUIRE_SECTIONS='Verdict' bash run-agent-async.sh start <prompt> <out> codex 1800`（缺省 xhigh） | `SURVEY_CURSOR_EFFORT=high SURVEY_REQUIRE_SECTIONS='Verdict' bash run-agent-async.sh start <prompt> <out> grok 1800`（**high 档**：它的 4 个角度靠联网取证不靠推理深度） |
| 等待规则 | 先 `wait` 它（codex xhigh 实测 ~3.5 min） | **软 deadline 900s**：主评审 DONE 后最多再等 15 min，到点未回先做单方矩阵，见下 |
| 失败后果 | 按替补链换族**重试 1 次**；替补也失败才跳过整个 Phase 6 + banner | **不阻断**，§metadata 标 `red-team: unavailable (<原因>)` |

**红队软 deadline（2026-09-10 加：红队是增量意见，不该占关键路径——此前它 xhigh 全文评审外推 10–20 min，是整个 survey 最慢的一段）**：
1. 两 job 同回合发出后，**先 `wait` 主评审**
2. 主评审 DONE 后，红队**最多再等 900s**：`wait <job-dir> 540` → 仍 RUNNING 再 `wait <job-dir> 360`
3. 到点仍 RUNNING → 只用主评审那份 verdict 做判断矩阵，§metadata 先标 `red-team: late (soft-deadline 900s)`；**不杀 job**（它自己的 deadline 1800s 会收尾）
4. 之后每次进入下一步**之前**（发 Round 2 / 发 Round 3 / 第 7 步分类 / finalize）先 `status` 看一眼红队：DONE → 其非 Concur 条目以 `[R1-红队·迟到]` 并入当前矩阵按四档表态（并集规则本就允许追加；红队条目不进 rebuttal，非 accept 直接挂到第 7 步——与准时到达时的流向完全一样）；到 finalize 仍未 DONE → 改标 `red-team: unavailable (soft-deadline)`
5. 迟到并入的条目照记进「红队增量」字段，别因为迟到就不记账

- **两个 job 必须同一回合发出**——串行会白多花 5-15 分钟
- **Round 1-3 这类全文评审必须走异步 job**：codex xhigh 实测 27KB prompt 205s（比 cursor-gpt 同任务 563s 快 2.7×），但更长的报告会触发更多搜索，不赌 570s 同步窗口；grok 族基础延迟高（263s 玩具 prompt 实测），更没有走同步的余地（见 helper §异步 job）
- **注入内容（两路相同）**：Brief + Source Quality 评分汇总（见 `../references/source-quality.md`）+ Phase 2.5 Reflection 结果（见 `../phases/03-reflection.md`）+ Phase 5.5 Citation Health（见 `../phases/05-citation.md`）
- 具体调用方式（exit code / timeout / prompt 文件命名规范 / 三族分工与替补链）见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)，**进入本段前必须 Read helper**

**红队 4 个角度（invariants，与主评审的 7 角度互补、不重叠）**：共识盲区（"大家都这么说所以没人查"的断言 + 出处链条是否只是互相转引）/ 反面证据缺席（失败案例、迁走复盘、生产事故搜过没有）/ 利益相关信源（vendor 文档、作者博客、融资通稿冒充独立证据）/ 被主流叙事盖住的选项。**允许直接 Concur**——红队不设"必须提 N 条"的指标，凑数比 Concur 更糟。

**Round 1 模板硬约束（invariants，主评审必须按这 7 个角度评审）**：
1. **Agent X1/X2 降权检查**：是否有 X1 或 X2 上报但被 Claude 降权 / 丢弃的 source 或方案（并集规则下丢弃即违规）
2. **Claude 偏好检查**：推荐是否非证据驱动地排 Anthropic 系工具靠前
3. **风险覆盖检查**：待验证风险是否覆盖训练截点后的版本变化 / maintainer 离职 / license 改变
4. **Brief 对照**：子问题清单全答？成功标准达标？信源约束遵守？
5. **Source Quality 对照**：High 质量 source 被用？Low source 是否 ≥2 独立来源交叉验证？
6. **Citation Health 对照**：dead URL / not-supported claim 是否有适当 caveat？
7. **信源排除**：补搜不搜中文社区

输出 verdict：Concur / Refine / Dissent；每条建议附 URL 证据，便于多轮辩论。

## Round 1 主 agent 判断矩阵

收到两份 verdict（主评审 + 红队；红队不可用时只有一份）后：

- **两份都 Concur**：跳过矩阵；§metadata 写一行 `Phase 6 verdict: 主评审 Concur / 红队 Concur; no changes requested; no additional claims introduced`（表达"reviewer 未提出修订"而非"报告无偏见"，防误读为权威背书）→ 进入 finalize（Phase 4）
- **任一 Refine / Dissent**：对**两份条目的并集**逐条做 4 档表态，写入 §metadata 子段 `Phase 6 辩论历史 > Round 1`

**双评审条目的合并规则（照搬 Phase 2 的并集精神）**：
- 每条标来源 `[R1-主评审]` / `[R1-红队]`，**两份都提的同一问题合成一条并标 `[两方共提]`**（共提本身是强信号，值得在矩阵里看得见）
- **两位 reviewer 互相矛盾时不投票、不取交集**：两条都保留、各自表态。谁也不因为"另一位没提"而被降权——这正是红队存在的意义
- 红队条目照走同一套四档规则与"禁止"清单，**但不进 Round 2/3**：它的非 accept 条目挂到第 7 步统一分类（事实性 → tiebreaker，判断性 → 人类裁决）
- 红队标了 `[前提类]` 的条目**同样不走四档**（见下方"禁止"最后一条）——原样进回问用户流程

**4 档判断规则**：
- **accept**：证据扎实、与主结论方向一致 → 直接 incorporate
- **partial**：证据部分成立但需打折 / 限定范围 → incorporate 时加 caveat
- **defer**：建议可能成立但证据强度不够支撑强表述 → 不 incorporate 为事实，放入 §待验证风险 或低置信度备注（典型例子：Series A 公告"采用"声明、未独立验证的产品宣传数据）
- **refute**：不 incorporate。必须标 `reason: unsupported`（reviewer 证据不足）或 `reason: contradicted`（主 agent 有反证，必附 URL / 引文）

**禁止**：
- 不要 refute 仅因"我不同意"——必须给 reason
- 不要 accept 仅因"权威给的"——必须给独立证据支持
- 不要把 partial / defer 当 escape hatch 用于规避表态
- **前提类建议不走四档**：凡 reviewer 建议实质动摇 Brief 前提（研究问题 / 比较对象 / 排除范围 / 用户澄清记录里用户亲口定的边界），无论证据多扎实都**不许直接 accept incorporate**——改走 `03-reflection.md` §前提破裂 的回问用户流程（非交互时同其降级）。两个 AI 达成一致不等于用户同意换靶

**Round 1 收敛条件**：全部 accept → 进入 finalize（Phase 4），跳过 Round 2/3。

## Round 2：主评审 rebuttal + 主 agent 二轮判断

仅当 Round 1 后存在**非 accept** 条目（partial / defer / refute）时触发。

**调度**：Round 2 调用主评审（codex；`SURVEY_CODEX_MODEL=<R1 实际 id>` 复用同一评审者，**`SURVEY_CODEX_EFFORT=high`**——反驳轮只看矩阵里的非 accept 条目，范围窄，high 够用，R1 才需要 xhigh；同样走 async）；失败时**提前进入人类裁决**（带 metadata banner 标注"AI 辩论未跑满 3 轮"）。注入内容：Round 1 矩阵（仅非 accept 条目）+ 主 agent 论据。

**Round 2 Rebuttal prompt 模板路径**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/round2-rebuttal.txt`（调度同 Round 1，见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)）。

**Round 2 模板硬约束（invariants）**：
- **仅反驳非 accept 条目**（partial / defer / refute）；accept 已收敛不重新挑起
- **三档反驳规则**：partial（限定是否合理）/ defer（证据是否够升 accept）/ refute（unsupported 补来源 / contradicted 回应反证）
- **允许撤回**：被主 agent 说服则明确"我撤回 Round 1 建议"，不勉强反驳
- **信息源排除**：同 Round 1（禁中文社区）

**主 agent 二轮判断**：读完主评审 rebuttal 后，对每条做新表态：

| 维持 / 让步 | 必备字段 |
|---|---|
| **维持原档** | 必附"为什么不被反驳说服"的论据（≥1 句；不能仅"我还是不同意"） |
| **让步并改档** | 必附"被哪个新证据/论据说服"（指向主评审 rebuttal 里具体句段） |

**禁止**：
- 不要让步仅因为"对方反驳得更激烈"——必须有新证据触发
- 不要维持仅因为"我已经写下来了"——必须有未被反驳触及的独立证据

**Round 2 收敛条件**：所有条目双方同档（全部 accept / 全部 partial 同 caveat / 主评审全部撤回 Round 1 建议）→ finalize（Phase 4）。

## Round 3：主评审二次 rebuttal + 主 agent 三轮判断

仅当 Round 2 后仍有分歧条目时触发。

**调度**：Round 3 调用主评审（codex，同 Round 2 复用 R1 的 id、`SURVEY_CODEX_EFFORT=high`）；失败时**提前进入人类裁决**（同 Round 2 处理）。注入内容：Round 2 后**仍分歧**的条目 + 主 agent 二轮论据。调度方式见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)。

**Round 3 主评审 prompt 与 Round 2 同结构**，但 prefix 加一句：

```text
这是辩论第 3 轮（最后一轮 AI 辩论）。之后剩余分歧将由人类裁决。所以这一轮请：
- 只对 Round 2 主 agent 给的新论据反驳；不要重复 Round 1/2 已被讨论的点
- 如果你认为已经穷尽证据但仍坚持原意见，明确写 "证据已穷尽，分歧应由人类裁决"
- 如果你认为主 agent 二轮论据有道理，撤回前述意见
```

**主 agent 三轮判断**：同 Round 2 规则。

**Round 3 收敛条件**：双方同档 → finalize（Phase 4）；仍有分歧 → 进入**事实核查 tiebreaker**（工作流第 7 步），之后剩余分歧才进人类裁决。

## 事实核查 tiebreaker（第三个模型，非投票）

**触发**：Round 3 后仍有 ≥1 条分歧。**先分类，再决定谁裁**。

### 为什么这不是"第三票"

三方投票会毁掉这个 skill 的核心价值：本 skill 防的是**漏**（训练盲区），多数投票会把"只有一方发现的真实方案"投掉；而且两个共享语料的模型可以联手压过正确的少数派——那正是 §设计原则 要防的 AI 回声室。所以 tiebreaker **只做一件事：把能查清的事实当场查清**，让人类不必为可查证的问题做裁决。**判断永远归人类**。

### 分类规则（主 agent 执行，逐条判定）

| 类型 | 判据 | 去向 |
|---|---|---|
| **事实性分歧** | **能用单一官方来源直接确证的客观状态**：某源是否存在/已失效、发布日期、版本号、benchmark 数值、某产品官方文档是否声明支持某特性、**官方是否已标记 deprecated/EOL** | → tiebreaker |
| **判断性分歧** | 任何含**好坏 / 优劣 / 快慢 / 值不值 / 适不适合 / "实际上是不是已经过时"**的定性描述；优先级排序、推荐次序、风险权重 | → 直接进人类裁决，**不送 tiebreaker** |

**边界最易被击穿的地方（异构评审 2026-07-21 指出）**：带技术名词的判断题会伪装成事实题。判别口诀——

- ✅ 事实：「官方 changelog 里 X 被标了 deprecated 吗」→ 有唯一官方答案
- ❌ 判断：「X 是不是已经过时了 / 还值不值得用」→ 同一事实下两个人可以有不同结论
- ✅ 事实：「官方文档说 X 支持 Y 吗」→ 查文档即可
- ❌ 判断：「X 对 Y 的支持够不够好」→ 定性

**拿不准算哪类 → 按判断性处理**（fail-closed：宁可多问人，不可让模型替人做取舍）。宁可漏送 tiebreaker，也不能让判断题溜进去——**LLM 有强烈的迎合倾向，给它一道判断题它极可能硬给个结论而不是标 `OUT_OF_SCOPE`**。

### 调度

- **选族规则（硬约束：必须与当轮主评审异族；族=训练实验室，codex 与主评审同族故**绝不**当裁判）**：默认 `gemini`；下列情况改用 `grok`：
  - gemini 族不可用（doctor 判死 / 调用失败）
  - 触发利益回避（见下条）
  - **例外**：主评审已按替补链降到 `grok` 时，tiebreaker 只能用 `gemini`；两族都不可用才判 `tiebreaker: unavailable`
- **不要复用红队的模型实例/id**：红队是本轮争议的当事评审者，让它给自己的条目当裁判等于自审自签。改用 grok 裁决时**重新解析一次**该族模型（helper §主 Claude 必须做 #2）
- **调用**：`bash run-cursor-agent.sh <prompt> <out> <gemini|grok>`
- prompt 模板：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/tiebreak.txt`（Read gate 同其他模板）
- **只调 1 次**：把所有事实性分歧批量注入，不要一条一次
- 无事实性分歧 → **跳过本步**，不空跑（省配额）
- **利益回避（2026-08-15 升级：先换族，换不掉才推给人）**：
  - 争议 source 来自 **X2（gemini）独有发现** → 该条改交 `grok` 裁，§metadata 标 `recusal: X2-sourced → grok`
  - 争议条目由**红队（grok）提出** → 该条改交 `gemini` 裁，§metadata 标 `recusal: red-team-sourced → gemini`
  - 两类回避撞在一起（X2 独有 source + 红队提出）→ 无可用异族裁判，直接转人类裁决并标 `recusal: 双向回避`
  - **回避条目与非回避条目分属不同族时，本步允许调 2 次**（每族各 1 次批量），仍计入 iteration bound
- 调用方式见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)

### verdict 处理

| verdict | 处理 |
|---|---|
| `REVIEWER_对` / `MAIN_对` / `都不对` | 按裁判结论收敛该条，**必须连同其依据 URL** 写进 §metadata；正文按结论修正 |
| `UNRESOLVED` | **转人类裁决**（fail-closed：查不到就别替人拍板） |
| `OUT_OF_SCOPE` | 说明主 agent 分类错了 → 归回判断性，转人类裁决 |

**硬约束**：
- 裁判结论**只对事实有约束力**，不得据此改动推荐排序 / 优先级等判断类表述
- 裁判**没给 URL 的 verdict 一律降级为 `UNRESOLVED`**——无证据的裁决就是第三个模型的臆断，比不裁更糟
- tiebreaker 调用失败 / 超时 → **先按 §调度 的选族规则换一次族重试**（gemini ↔ grok，计入 iteration bound）；换族后仍失败、或压根没有可用异族 → 事实性分歧原样转人类裁决 + metadata 标注 `tiebreaker: unavailable (<原因>)`

## 人类裁决

**触发**：tiebreaker 后仍有 ≥1 条未收敛分歧（判断性分歧 + `UNRESOLVED` + `OUT_OF_SCOPE` + 利益回避条目）。**若 tiebreaker 把全部剩余分歧都裁清了 → 跳过本步直接 finalize**（这是合法收敛路径，不需要硬造问题去问用户）。

**执行**：用 AskUserQuestion 暴露每条分歧。

格式约束：
- 每条分歧作为独立 question
- options 至少 3 个：`采纳主 agent 立场` / `采纳 reviewer 立场`（注明是主评审还是红队）/ 实质性独立判断（如 `维持 defer 但范围更窄`、`改 accept 但加强 caveat` 等具体替代）
- 分歧条目 ≤4 → 一次性问；>4 → 分批每批 ≤4

**用户裁决后**：
- 按用户最终立场 finalize（Phase 4）
- 不再回外部模型重审（人类即终审）
- §metadata 记录用户裁决 + 备注

## iteration bound

- AI 辩论最多 3 轮（Round 1 + Round 2 rebuttal + Round 3 rebuttal）；**红队只占 Round 1 的 1 次，不参与 rebuttal**
- 外部模型总调用 ≤ **6** 次，**分池记账**：codex ≤3（主评审 R1–R3，即使 Round 1 直接 Concur 也算 1 次）；cursor ≤3（红队 ≤1 + 主评审失败按替补链换 grok 重试 ≤1 + tiebreaker ≤1）。**tiebreaker 因利益回避分两族批量、或失败换族重试时，最多允许 2 次**（此时总数 ≤7）
- **整个 survey 的外部模型总调用硬上限 10 次**：codex ≤4（X1 1 + R1–R3 ≤3）+ cursor ≤6（X2 1 + Phase 2.5 追搜 ≤1 + 红队 1 + 替补重试 ≤1 + tiebreaker ≤2）。**codex 调用不加路**——它烧的是用户日常写码的 ChatGPT 订阅额度（按小时/周窗口滚动），"它快所以多跑几路"这条路堵死。Phase 5.5 失败触发的"回 Phase 2 重搜"**只重跑 Claude 补搜，不重跑 X1/X2**（异构眼每 survey 只跑一次）——否则成本没有上界
- **唯一例外：用户裁决换靶**（`03-reflection.md` §前提破裂）——用户亲口选"换靶重立 Brief"时计数清零、X1/X2 对新 Brief 各允许再跑 1 次；换靶整个 survey 最多 1 次，所以总成本仍有上界（≤20 次）
- tiebreaker **不可循环**：判完就是判完，不因主 agent 不服再跑一次
- 主 agent 判断 ≤ 3 次
- 人类裁决 1 次（不可循环）

## 降级

- **Round 1 主评审不可用 → 先按替补链换族重试 1 次**（`codex → grok → gemini`，helper §三族分工；codex 的 67/68/69 与 doctor 判死都算不可用）。替补也失败才跳过整个 Phase 6，并**由 Phase 6 自己在报告顶部补 banner**：

  ```markdown
  > ⚠️ **PHASE 6 DEBATE SKIPPED**
  > Reason: <exit code 对应原因>
  > Implication: 报告未经异构终审，只走到 Phase 5.5；结论未被独立模型挑战过
  ```

  **不要以为 Phase 2 的 banner 已经涵盖**——Phase 2 两只眼都成功时**根本没写 banner**，此时 Phase 6 静默跳过会让用户误以为报告过了终审。这条是异构评审（Gemini lens, 2026-07-21）指出的静默失败。
- **Round 1 红队（grok）失败或软 deadline 内未回** → **不阻断**：照常用主评审那份 verdict 走判断矩阵，§metadata 标 `red-team: unavailable (<原因>)` / `red-team: late (soft-deadline 900s)`（迟到的在后续步骤前并入，见 §Round 1 软 deadline）。红队是增量意见不是质量门禁，**绝不**因为它挂了就跳过 Phase 6，也**绝不**换族顶替（换成 codex/gpt 就成了主评审自己审自己，换成 gemini 又和 tiebreaker 撞族）
- 主评审 Round 2 / Round 3 调用失败 → 提前结束辩论，但**仍先走 tiebreaker**（主评审挂了不代表裁判族挂了；事实性分歧该查还得查），之后剩余分歧再进人类裁决（带 metadata banner 标注"AI 辩论未跑满 3 轮"）
- **tiebreaker 调用失败** → 先按选族规则换族重试 1 次（gemini ↔ grok）；仍失败或无可用异族 → 事实性分歧原样转人类裁决 + §metadata 标 `tiebreaker: unavailable (<原因>)`；**绝不**改用与主评审同族的模型顶替（同族自审没有增量，等于给回声室盖章）
- **Phase 2 的 X1(codex) 挂但 X2(gemini) 活着**（或 doctor 已判 codex 通道死）→ Round 1-3 主评审按替补链改用 **grok** 族；此时红队取消（同族），tiebreaker 用 gemini。**只有 grok 也不可用时**主评审才落到 gemini，那种情况下 tiebreaker 才真的无异族可用、事实性分歧全部转人类裁决。注意 X1 挂是 codex 通道的事，与 Cursor 通道无关——不要因为 X1 挂就假定 grok/gemini 也挂
- AskUserQuestion 不可用（极少情况）→ §metadata 标注 "分歧未裁决"，正文不 incorporate 分歧条目
