# Phase 2：多源研究

> **强制异构搜索**：Phase 2 始终是 2 Claude + **2 个不同族的 cursor-agent**，无用户可控的 opt-out。两只眼各自独立降级（见下方 §自动降级矩阵）。

## 路数分档（2026-07-31 加）

**异构两路（X1 gpt + X2 gemini）任何档位都不可省**——那是本 skill 的立身之本。可调的只有 Claude 路数：

| 档 | Claude 路数 | 判据 |
|---|---|---|
| 重大决策 | 3（A 通用 + B 技术 + C 社区反证） | 会改架构/宪法/对外承诺的调研 |
| 常规（默认） | 2（A 通用 + B 技术） | 选型、最佳实践、方案比较 |

**轻量事实核实不要用 /survey**（如"某 API 现在还支持吗""某工具最新版本行为"）——直接 WebSearch/WebFetch，几秒就够，用 survey 是杀鸡用牛刀。

## 默认模式（2 Claude + 2 cursor-agent，四路并行）

Phase 1.5 Brief 完成后，启动 4 个并行 agent——其中 2 个是 cursor-agent，**分属不同模型家族**（模型不钉版本，运行时按家族各自解析当前最强，见 `../references/cursor-agent-invocation.md` §模型选择）：

```
Agent A（Claude，通用 + 主流）
  任务：搜索通用方案概览、官方文档、权威博客
  禁止：不看 Agent B/X1/X2 的搜索结果
  工具：WebSearch, WebFetch

Agent B（Claude，技术 + 实现）
  任务：搜索开源项目实现、技术论文、GitHub 仓库
  禁止：不看 Agent A/X1/X2 的搜索结果
  工具：WebSearch, WebFetch

Agent X1（cursor-agent · family=gpt，第一异构 lens）— 替换原 Claude Agent C
  调用：SURVEY_CURSOR_EFFORT=high bash run-cursor-agent.sh <prompt> <out> gpt
        （high 档：搜索是检索型任务，xhigh 的深推理徒增等待，见 helper §档位配置）
  任务：4 类 **Claude 盲区**针对性搜索
  prompt：prompts/agent-x.txt

Agent X2（cursor-agent · family=gemini，第二异构 lens）
  调用：bash run-cursor-agent.sh <prompt> <out> gemini（gemini 无 effort 档）
  任务：4 类 **Claude+GPT 共同盲区**针对性搜索（搜索引擎可见性偏差 / 非美系英文文档
        生态 / 学术已解决工业未流行 / 已废弃被取代的方案）
  prompt：prompts/agent-x2.txt
```

**为什么第二只眼查的是"共同盲区"而不是重复查 Claude 盲区**：Claude 与 GPT 同为美国实验室、训练语料高度重叠，会**一起**漏掉同一批东西（低网络声量的厂商文档 / 标准规范 / 非美系英文生态）。X2 只有瞄准这个补集才有增量价值；让它重跑 X1 的清单等于花配额买重复。

**prompt 模板路径**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/prompts/agent-x.txt`（X1）与 `prompts/agent-x2.txt`（X2）。Read gate 见 SKILL.md §Prompt Template Read Gate；调度方式见 §cursor-agent 调度。

主 Claude 在两份 prompt 模板顶部各注入 Brief 全文作为 prefix（两个模板都已留占位符）。

**X1 / X2 模板硬约束（invariants）**：
- **盲区清单不许互换**：X1 = 4 类 Claude 盲区（训练截点后新工具 / Anthropic 生态偏移 / "主流"定义偏差 / 小众但成熟方案）；X2 = 4 类 Claude+GPT 共同盲区
- **信息源排除**：不搜中文社区（CSDN / 掘金 / 思否 / 简书 / 知乎技术专栏 / 微信公号 / gitee / 国产 SaaS）；日文/俄文/欧洲方案如出现英文索引中可保留，不主动用非英文关键词
- **输出强制二段式**（#5 Context Isolation）：`## Compressed Findings` (~500 字 / 5-8 条 finding 标 confidence + URL) + `## Source Inventory`（URL / 摘要 / 日期 / 标签 / Quality）
- 最少 5 个 source，最少 1 个近 12 月（按 currentDate 算）

## 合并规则：并集，不投票（硬约束）

综合 agent 收到四方结果（A+B+X1+X2）后合并，**合并规则是并集**：

- **绝不**因为"只有一方报了"就丢弃一条发现。本 skill 的失效模式是**漏**（训练盲区导致漏掉真实存在的方案），不是编——4 路里只有 1 路搜到的冷门方案，恰恰是异构最大的价值所在，多数投票会把它投掉
- 只有 1 方报的发现：**保留**，标 `single-source`，并在 Phase 2.5 Reflection 里优先安排补搜坐实
- 多方都报但**内容冲突**的：保留冲突，写进"分歧点"，交 Phase 5.5 Citation Health 与 Phase 6 处理，不在此处强行收敛
- **特别标注 X1 / X2 独有的 source**（即"Claude 没搜到、异构 lens 搜到的"），并标明来自哪只眼——这是异构核心价值的体现，也是判断要不要继续付这份配额的依据

> 投票只在 Phase 6 的**事实性分歧**上出现（见 `06-debate.md` §事实核查 tiebreaker），发现阶段永远是并集。

### 并集的配套闸门：证实不了的必须 Drop（不是加 caveat）

并集提高召回，代价是**幻觉也会被并进来**——多一只眼就多一条幻觉入口。所以并集**只对"存在性能被交叉验证"的发现成立**，配套硬闸门：

- `single-source` 发现 → Phase 2.5 必须安排补搜；**补搜找到独立佐证** → 升为正常发现；**补搜找不到** → 进入下一条判定
- **未获佐证的 `single-source` 发现不得进入 §推荐 与评分矩阵**——可以留在正文的"候选/待验证"区（附 confidence 与来源标注），但不能参与打分、不能被推荐引用为论据。并集管的是**候选召回**，不是**结论资格**
- **补搜无果 + 其引用 URL 在 Phase 5.5 判为 dead / not-supported** → **直接从正文 Drop**，只在 §metadata 的 `未证实已剔除` 清单里留一行（原文一句话 + 来自哪只眼 + 为什么被剔除）
- **绝不**用"链接已失效"之类的 caveat 把证实不了的东西留在正文里——那不是谨慎，那是把垃圾贴上标签再端给用户
- Phase 5.5 的 dead URL 比例阈值是**报告级**总闸门，管不住"单条幻觉但整体比例达标"的情况；本条是**逐条**闸门，两者互补，都要执行

> 这条是异构评审（Gemini lens, 2026-07-21）逼出来的：它指出原来的并集规则加上"dead URL 只加 caveat"，等于给幻觉发了进正文的通行证。

**并发协调**（主 Claude 必读）：
- Agent A、B 是 Claude subagent（用 Agent/Task 工具启动）
- Agent X1、X2 是外部 Bash subprocess（各调一次 `run-cursor-agent.sh`，family 参数不同）
- 四者**并发启动**——同一回合 message 内同时发 2 个 Agent 工具调用 + 2 个 Bash 工具调用；X1/X2 并行，墙钟基本不变（各约 5 min）
- **两个 Bash 调用必须用不同的 prompt / output 文件名**（`survey-x1-*` / `survey-x2-*`），否则互相覆盖
- 主 Claude 在收到四方返回后再启动综合 agent；不要串行启动 X1/X2，会白白多花 ~5 min

## Sub-agent 输出格式（强制 #5 Context Isolation）

> **原则**：sub-agent 完整 markdown 报告（~3000 字）回到综合 agent 时会撑爆 context。Anthropic 工程 blog 明确说"isolated context windows is biggest single win"。所有 sub-agent（A / B / X1 / X2、以及 Phase 2.5 追搜 agent）**必须**返回二段式：

```text
## Compressed Findings（~500 字，硬上限 800 字）

5-8 条核心发现，每条格式：
- **<finding title>** [confidence: high/medium/low]
  <一句话内容>。证据：<URL1>; <URL2>

## Source Inventory（结构化完整来源）

| URL | 一句摘要 | 发布日期 | 标签 | Source Quality 评分 |
|---|---|---|---|---|
| https://... | ... | YYYY-MM-DD | primary/secondary/official/blog/paper | High/Medium/Low（见 ../references/source-quality.md） |
| ... |
```

**综合 agent 读取规则**：
- 默认只读四方的 Compressed Findings + Source Inventory
- 遇到分歧或需要溯源时，才回查 sub-agent 原文（通过 agentId SendMessage 询问，或要求 sub-agent 补充）
- 不要把四方完整 3000 字报告全塞进综合阶段 context

## 自动降级矩阵（X1 / X2 各自可能失败）

两只异构眼**各自独立降级**，一只挂不影响另一只：

| 情况 | 行为 | banner |
|---|---|---|
| X1、X2 都成功 | 正常四路并集 | 无 |
| X1 挂、X2 成功 | 继续（3 路：A+B+X2）；Phase 6 主评审按替补链改用 **grok** 族（grok 也不可用才退 gemini），此时红队取消 | `⚠️ HETEROGENEOUS LENS PARTIAL: GPT lens 缺失` + 原因 |
| X2 挂、X1 成功 | 继续（3 路：A+B+X1）；Phase 6 主评审仍用 gpt，**tiebreaker 改用 grok**（不再直接判不可用） | `⚠️ HETEROGENEOUS LENS PARTIAL: Gemini lens 缺失` + 原因 |
| 两只都挂 | 退到 3 Claude 经典并行（见下），**Phase 6 整段跳过** | `⚠️ HETEROGENEOUS REVIEW: SKIPPED` |

**判定依据**：各自的 exit code（见 `../references/cursor-agent-invocation.md` §exit code）。**绝不**因为一只眼挂了就放弃另一只。

> **grok 族为什么不在这张表里**：grok 不做搜索眼（2026-08-15 实测该族基础延迟高，263s 玩具 prompt，完整搜索任务会撞同步窗口），它只在 Phase 6 出场——红队第二评审 + 主评审/tiebreaker 的替补族。所以 Phase 2 的降级判定仍然只看 X1/X2 两只眼；grok 的可用性由 `doctor.sh` 单独报一行，死了只 WARN 不改 Phase 2 的档位。

### 两只都不可用时：退回 3 Claude

cursor-agent CLI 不可用（`command -v cursor-agent` 失败）或两次调用都失败 / 超时（>570s）时，**自动**退回到 3 Claude 经典并行——用户无法主动选择此路径，仅作为 fallback：

```
Agent A（通用 + 主流）
  任务：搜索通用方案概览、官方文档、权威博客
  禁止：不看 Agent B/C 的搜索结果

Agent B（技术 + 实现）
  任务：搜索开源项目实现、技术论文、GitHub 仓库
  禁止：不看 Agent A/C 的搜索结果

Agent C（社区 + 经验）
  任务：搜索 HN/Reddit/StackOverflow 上的讨论、踩坑经验、真实反馈
  禁止：不看 Agent A/B 的搜索结果
  信息源排除：不主动用中文关键词搜索；不优先使用 CSDN/掘金/思否/简书/知乎技术专栏/
              微信公众号/gitee/国产 SaaS 作为论据（用户反馈：中文社区信息杂乱落后）
```

**并行独立的原因**：三个 Agent 各自独立搜索，防止一个 Agent 的早期发现锁定后续搜索方向；A/B/C 视角天然不同，分歧点本身就是最有价值的信息。

**报告顶部加 banner**（不是末尾埋）：

```markdown
> ⚠️ **HETEROGENEOUS REVIEW: SKIPPED**
> Reason: <cursor-agent not found | timeout >570s | auth failure | quota exhausted | empty output>
> Implication: 所有 source 来自 Claude lens，训练数据盲区未被独立模型审查；高风险决策建议安装 cursor-agent 后重跑（cursor.com/cli）
```

一只眼挂时用 PARTIAL banner（**别用 SKIPPED**，那会误导成"完全没异构"）：

```markdown
> ⚠️ **HETEROGENEOUS LENS PARTIAL: <GPT | Gemini> lens 缺失**
> Reason: <exit code 对应原因>
> Implication: 仍有一只异构眼覆盖，但 <该族> 视角的盲区未被审查<；且事实性分歧 tiebreaker 不可用，全部转人类裁决——仅 Gemini 缺失时加这句>
```

**绝不**因异构失败让主流程失败。

## cursor-agent 调度（最小硬约束）

- **启动 X1/X2 前先跑一次自检**：`bash doctor.sh`（秒级快检，不耗配额；exit 0=HEALTHY / 1=DEGRADED / 2=BROKEN）。非 0 时**提前**把即将发生的降级与修复建议告知用户（doctor 已给出确切命令），不要等 Phase 2 跑到一半才用 banner 揭晓；能自动修的（脚本执行位）doctor 会当场修掉。**doctor 结果绝不阻塞主流程**——BROKEN 也照走降级矩阵
- **必须调用 cursor-agent 跑 X1（gpt）与 X2（gemini）两只眼**（异构 lens 是 Phase 2 设计核心）
- **两只眼各自独立降级**；两只都不可用才退到 3 Claude（Agent X 换 Agent C）+ 报告顶部 banner（见上方 §自动降级矩阵）
- **失败不阻塞主流程**——降级是设计目标，不是异常

具体调用方式（4 硬点 / exit code 表 / Bash timeout / prompt 文件命名规范）见 [`../references/cursor-agent-invocation.md`](../references/cursor-agent-invocation.md)，**进入本段前必须 Read helper**。
