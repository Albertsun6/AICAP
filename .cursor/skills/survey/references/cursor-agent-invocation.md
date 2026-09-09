# 异构通道调用 Helper（codex + cursor-agent）

> /survey 在 Phase 2（X1/X2 双异构搜索）和 Phase 6（主评审 + grok 红队第二评审 + Round 2/3 rebuttal + 事实核查 tiebreaker）调用外部模型。**两条通道**：`codex` CLI（ChatGPT 订阅，GPT 族）与 `cursor-agent` CLI（Cursor 订阅，gemini + grok 族）。所有调用细节集中在此，避免 phase 文件重复。文件名沿用 `cursor-agent-invocation.md` 是为了不动 Read gate 表与 doctor 清单；内容已覆盖两条通道。

## 通道与族（2026-09-09 重定义，硬约束）

**族 = 训练它的实验室（Lab），不是 CLI、不是订阅、不是配额池。**

| 族 | 通道 | 实际模型（2026-09-09 实测解析） | 调用点 |
|---|---|---|---|
| `codex`（GPT / OpenAI） | `codex exec`，ChatGPT 订阅 | `gpt-6-astra`（目录 priority=1） | X1 搜索眼；Phase 6 主评审 R1/R2/R3 |
| `gemini`（Google） | `cursor-agent`，Cursor 订阅 | `gemini-3.1-pro` ⚠️ 该族在 Cursor **唯一**非 flash 候选 | X2 搜索眼；事实 tiebreaker |
| `grok`（xAI） | `cursor-agent`，Cursor 订阅 | `cursor-grok-4.6-xhigh` | 红队第二评审；主评审/tiebreaker 替补族 |

- **gpt 族在 cursor 通道退役**：OpenAI 因 SpaceX 收购 Cursor 触发控制权变更条款，宣布 2026-11-12 切断 Cursor 的模型访问且不再供新模型（[CNBC 2026-08-29](https://www.cnbc.com/2026/08/29/openai-cursor-spacex-model-access.html)、[OpenAI 声明](https://openai.com/index/our-decision-on-cursor-following-its-acquisition-by-spacex/)）。`run-cursor-agent.sh` 收到 `gpt` 直接 exit 64 指向 `run-codex.sh`。
- **换通道不构成换族**：`codex` 的 `gpt-6-*` 与（已退役的）cursor `gpt-5.6-*` 同属 OpenAI。任何时候 **codex 不得占据红队或 tiebreaker 席位**——那是"主评审自己审自己"，与 SKILL.md「主评审与 tiebreaker 必须异族、绝不允许同族自审自签」直接冲突。同理 `gemini`/`grok` 换成别的 CLI 也还是 Google/xAI。
- **通道独立才是这次改动买到的东西**：X1(codex) 与 X2(cursor) 各有各的凭据、配额池、harness 与检索后端。Cursor 池见底只灭 X2/红队/tiebreaker，X1 与 Phase 6 主评审照跑；反之 ChatGPT 用量撞墙只灭 X1 与主评审（主评审按替补链换 grok）。此前三族共一个 Cursor 池，"两眼各自独立降级"在最高频失效模式（额度）下是假的。
- **异构度的诚实账**：同为 GPT 族的 codex 与 cursor-gpt 在**判断轴**上是同源的；但检索后端不同——同一份 X1 prompt 实测独有 URL codex 18 条 vs cursor 9 条（共享 8 条）。它买的是**召回多样性 + 可用性独立**，不是判断多样性。

## 调用点一览（谁用哪个族 / 哪条通道）

| 调用点 | family | 脚本 | 同步/异步 | prompt 模板 | 文件名前缀 |
|---|---|---|---|---|---|
| Phase 2 Agent X1 | `codex` | `run-agent-async.sh … codex 900` | **异步**（high 档实测 302–491s，贴同步窗口） | `prompts/agent-x.txt` | `survey-x1-` |
| Phase 2 Agent X2 | `gemini` | `run-cursor-agent.sh … gemini` | 同步（实测 188–300s） | `prompts/agent-x2.txt` | `survey-x2-` |
| Phase 2.5 追搜（如需） | `gemini`（或 Claude agent） | `run-cursor-agent.sh … gemini` | 同步 | 定向 prompt | `survey-x25-` |
| Phase 6 Round 1/2/3 **主评审** | `codex`（替补链见下） | `run-agent-async.sh … codex 1800` | **异步**（xhigh 实测 205s，不赌同步窗口） | `prompts/round1.txt` / `round2-rebuttal.txt` | `survey-r1-` / `r2-` / `r3-` |
| Phase 6 Round 1 **红队第二评审**（one-shot） | `grok` | `run-agent-async.sh … grok 1800` | **异步**（该族基础延迟高） | `prompts/round1.txt` + `prompts/round1-grok-prefix.txt` | `survey-r1g-` |
| Phase 6 事实 tiebreaker | `gemini`（回避/不可用时 `grok`） | `run-cursor-agent.sh … gemini\|grok` | 同步 | `prompts/tiebreak.txt` | `survey-tb-` |

### 三族分工与替补链

- **搜索眼**：X1=`codex`、X2=`gemini`。grok **不做搜索眼**——2026-08-15 实测它跑一个只有 2 问的玩具 prompt 就要 263s，完整搜索任务大概率撞同步窗口
- **主评审替补链**：`codex → grok → gemini`。codex 不可用（67/68/69/124）→ 换 grok（红队取消，同族没增量）→ grok 也不可用才落到 gemini（此时 tiebreaker 无异族可用，事实性分歧全部转人类）
- **红队第二评审**：固定 `grok`，**one-shot**（只在 Round 1 出场）。它是增量意见不是质量门禁，挂了不阻断主流程
- **tiebreaker 选族**：**必须与当轮主评审异族**，在存活族里**优先 `gemini`**；gemini 不可用、或触发利益回避（争议 source 来自 X2）时改用 `grok`。**绝不**用 codex（与主评审同族）。只有「所有非主评审族都不可用」才标 `tiebreaker: unavailable`
- **主评审已降到 grok 时**：红队取消，tiebreaker 只能用 `gemini`

## 调用 4 硬点

1. **统一走脚本，按族选脚本**：
   - `codex`：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/run-codex.sh <prompt-file> <output-file>`
   - `gemini` / `grok`：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/run-cursor-agent.sh <prompt-file> <output-file> <gemini|grok>`（族**必须显式给**，无默认）
   - 异步一律 `run-agent-async.sh start <prompt> <out> <codex|gemini|grok> [deadline]`（按族自动路由到上面两个 runner）
   - 不内联 bash（避免变量展开 / ARG_MAX / 临时文件清理出错）
2. **prompt 必须用 Write 工具生成**到 `/tmp/survey-<前缀><unix-ts>-<4位随机>.txt`（前缀见上表）；**禁用 heredoc / cat 内联**。**X1 与 X2 并发跑，文件名前缀必须不同**；加随机段是因为用户常同开多窗跑 survey，秒级时间戳会跨窗口撞名互相覆盖
3. **同步/异步按上表，都不许裸调**：
   - **同步**（X2 / 追搜 / tiebreaker）：Bash 工具 timeout 参数固定 `600000`（600s 是工具硬上限，`BASH_MAX_TIMEOUT_MS` 有已知 bug 调不动）。脚本内层 watchdog 默认 **570s**，**内层必须比外层小**
   - **异步**（X1 / Phase 6 全部评审轮次）：**必须走 `run-agent-async.sh`**（见 §异步 job）。X1 在 codex high 档实测 302–491s（搜索指令密度决定耗时，不是 prompt 大小），同步窗口太贴；主评审 xhigh 实测 205s（27KB prompt）但更长的报告会更慢，不赌
   - **段落校验交给脚本**：启动 X1/X2 时设 `SURVEY_REQUIRE_SECTIONS='## Compressed Findings|## Source Inventory'`，Phase 6 评审设 `SURVEY_REQUIRE_SECTIONS='Verdict'`，缺段在 job 内按 66 判掉
4. **exit code → 降级路径完整映射**（两个 runner 同一张表）：

   | code | 含义 | 降级行为 |
   |---|---|---|
   | `0` | 成功 | Read 输出文件 |
   | `64` | 参数错（含把 `gpt` 传给 cursor runner / codex CLI flag 契约变了） | 主 Claude 修正调用或改脚本，**不是降级场景**，fail-loud |
   | `69` | CLI 未安装 | + banner "<codex\|cursor-agent> not found" |
   | `124` | timeout（同步 >570s / 异步 >deadline） | + banner "timeout" |
   | `67` | **认证失效** | + banner "auth failure"，Reason 写 `auth failure`；**不回落、不降级重试**，先让用户 `codex login` / `cursor-agent login` |
   | `68` | **用量/额度耗尽**（cursor=月度池；codex=按小时/周滚动窗口） | + banner "quota exhausted"。撞墙写状态文件供 doctor L3.5 读取 |
   | `65` | 调用失败（network / 模型不在实时列表或目录 / codex 认证判不出） | + banner "error" |
   | `66` | 空输出或缺约定段落 | + banner "returned empty output" |

### codex 通道的失败形态（与 cursor 的差异，主 Claude 要知道）

- codex exec 的 401 认证 / 400 模型不存在 / 配额墙**全部 exit 1**——runner 靠 `--json` 事件流分类，主 Claude 只看 runner 的 exit code 即可
- **exit 68 的判据是推断**：本机订阅未耗尽，没能真撞墙；文案锚定 codex 二进制里的用户可见字符串（"You've hit your usage limit…" / "Upgrade to Plus|Pro to continue using Codex" / `usage_limit_reached`）。**真撞墙那次必须回来把原文钉进 `run-codex.sh`**
- codex 用量窗口是按小时/周滚动（`/status` 里看），不是月度；doctor L3.5 的 24h 留痕 TTL 对它偏保守
- 失败时 `-o` 文件**不会被创建**（runner 已处理：调用前 rm、成功后判 -s）
- **配额外部性**：codex 走的是用户自己的 ChatGPT 订阅（plan=prolite），survey 烧的是用户日常写码的 Codex 额度。所以 **codex 调用不加路**：单次 survey ≤4 次（X1 1 + R1–R3 ≤3；替补重试走 grok）

## 各调用点的降级路径

| 调用点 | 失败时 |
|---|---|
| Phase 2 Agent X1（codex） | X2 活着 → 继续 3 路 + PARTIAL banner，**Phase 6 主评审按替补链改用 grok**（grok 也不可用才退 gemini）；X2 也挂 → 退 3 Claude + SKIPPED banner |
| Phase 2 Agent X2（gemini） | X1 活着 → 继续 3 路 + PARTIAL banner，**tiebreaker 改用 grok**；X1 也挂 → 退 3 Claude + SKIPPED banner |
| Phase 6 Round 1 主评审（codex） | 按替补链换族**重试 1 次**（grok → gemini，计入 iteration bound）；替补也失败才跳过整个 Phase 6 + banner "HETEROGENEOUS REVIEW: SKIPPED" |
| Phase 6 Round 1 红队（grok） | **不阻断**——照常用主评审那一份 verdict 走判断矩阵，§metadata 标 `red-team: unavailable (<原因>)` |
| Phase 6 Round 2 / 3 | 停止后续辩论轮次，**仍执行第 7 步 tiebreaker**，再进人类裁决；带 metadata banner 标注"AI 辩论未跑满 3 轮" |
| Phase 6 tiebreaker | 先按 §三族分工 的选族规则换族（gemini ↔ grok）；**所有非主评审族都不可用**才把事实性分歧原样转人类裁决 + metadata 标 `tiebreaker: unavailable`；**绝不**用与主评审同族（codex）顶替 |

完整矩阵见 `phases/02-research.md` §自动降级矩阵 与 `phases/06-debate.md` §降级。

## 调用模式（主 Claude 拼装步骤）

```text
1. Read 对应 prompt 模板（agent-x.txt / agent-x2.txt / round1.txt / round1-grok-prefix.txt / round2-rebuttal.txt / tiebreak.txt）
2. 注入 context（Brief 全文 / Source Quality 评分 / Phase 2.5 Reflection / Phase 5.5 Citation Health /
   Round 1-N 历史矩阵 / tiebreaker 的事实性分歧清单）
3. Write 到 /tmp/survey-<前缀>prompt-<unix-ts>-<随机>.txt
4. 按上表调 runner（同步：Bash timeout=600000；异步：run-agent-async.sh start → 后台 wait）
5. Read 输出文件（exit 0）或 + banner（其他 exit code）
6. **结构校验**：runner 已按 SURVEY_REQUIRE_SECTIONS 把缺段判成 66；主 Claude 仍要看内容是否跑题
   （schema/段名只管形状不管实质：实测存在段落齐全但内容是占位符的情况）
```

**Phase 2 的 X1/X2 必须在同一回合并发发出**（2 个 Agent 工具调用 + X1 的 async start + X2 的同步 Bash）。
**Phase 6 的 Round 1 主评审与红队同理**：同一回合发 2 个 async job（前缀 `survey-r1-` / `survey-r1g-`），串行会白多花 4–15 min。

## 模型选择

### cursor 通道（gemini / grok）：不钉版本，每次运行时解析该族最强

脚本每次跑 `cursor-agent --list-models`（约 1s，独立 20s deadline），按族解析：

| family | 规则 | 2026-09-09 实测 |
|---|---|---|
| `gemini` | `^gemini-` 且含 `pro`（无 effort 后缀） | `gemini-3.1-pro` ⚠️ 13 个 gemini 里唯一非 flash |
| `grok` | `^cursor-grok-` 且 `-high`/`-xhigh` 结尾 | `cursor-grok-4.6-xhigh`（EFFORT=high → `-high`） |

- 全族通排：`-fast` / `-none -low -medium` / `-max`（690s 必超同步窗口）/ `-codex -mini -nano -lite -flash` / `-preview -realtime -audio -image -embed -tts`；排除项**必须带前导 `-` 按分段匹配**（裸 `mini` 会误杀 ge-**mini**）
- 取列表失败 / 超时 / 无候选 → 回落 `FALLBACK_MODEL`（WARN）；**认证失效 exit 67 不回落**
- **幽灵 id fail-closed（2026-09-09 加）**：解析结果（含钉值/回落值）不在实时列表 → run 模式 exit 65 跳过调用，不烧一次必失败的请求；`--resolve-only` 仍打 id 并 WARN 供 doctor 复核。gemini 的 FALLBACK 就是它要保护的那个单点，它下架时会走到这里而不是假成功
- 手动钉：`SURVEY_CURSOR_MODEL=<id>`（前缀必须匹配 family，否则忽略回自动解析——防 export 后忘 unset 导致 tiebreaker 偷偷串族）；`SURVEY_CURSOR_EFFORT=high|xhigh`（仅 grok 族有档）

### codex 通道：读本地目录，**不保证"最新最强"**

codex 无 `--list-models` 等价物。`run-codex.sh` 读 `codex debug models` 的本地目录（`models[]` 的 slug / visibility / priority / supported_reasoning_levels），取"可见、支持目标 effort、priority 最小"的 slug（priority 由服务端下发，1=最强，**启发式非承诺**），排除 `codex/mini/nano/lite/spark/preview`。2026-09-09 解析出 `gpt-6-astra`。

⚠️ 三条必须知道的不对称：
- **目录解析不是可用性证据**：断网 exit 0（读缓存）、未登录 exit 0（返回另一份内置目录）。所以 `--resolve-only` 的 stderr 强制打 `AUTH: unverified`，认证由 `--auth-check` 单独实打（零配额，curl 打 codex 自己刷目录的端点；判不出时用 `codex doctor --json` 的 websocket 握手当第二意见）。**doctor 判 codex 可用必须两者都过**
- 目录是缓存（`fetched_at`），超 24h 标 `-stale` 并 WARN；任何一次真调用会刷新它
- 钉值/回落值不在目录 → 标 `-unlisted`，run 模式 exit 65 跳过（codex 对未知 id 会先本地降级再被服务端 400，不复核就白烧一次）

手动钉：`SURVEY_CODEX_MODEL=<id>`；档位 `SURVEY_CODEX_EFFORT=low|medium|high|xhigh`（缺省 xhigh）。

### 档位配置（按任务复杂度配 effort，不是全阶段无脑最强）

| 调用点 | effort | 为什么 |
|---|---|---|
| Phase 2 X1（codex） | **`SURVEY_CODEX_EFFORT=high`** | 检索型任务，耗时由搜索指令密度决定；实测 high 302–491s、xhigh 604s |
| Phase 2 X2（gemini） | 无档 | gemini-3.1-pro 无 effort 后缀 |
| Phase 6 主评审 R1–R3（codex） | 缺省 xhigh | 全管线最难的推理任务；实测 27KB prompt 205s，比 cursor-gpt 同任务 563s 快 2.7× |
| Phase 6 红队（grok） | 缺省 xhigh | 同上；必须 async |
| tiebreaker | 无关 | 事实核查靠联网 |
| doctor `--probe` | codex 用 low | 探针验的是"调得通"，档位无关，少烧订阅额度 |

**主 Claude 必须做**：
1. 报告 §调研 metadata 的 `异构模型` **必须抄 runner 打出的实际值**（`MODEL:` 行 / `OK:` 行），X1 / X2 / R1 主评审 / R1 红队各一，不许凭记忆写版本号
2. **同一次调研内按"任务类"各解析一次**：X1 自己解析（high）；Phase 6 R1 主评审自己解析（xhigh），**R2/R3 复用 R1 的 id**（`SURVEY_CODEX_MODEL=<R1 实际 id>`）——同一份报告的多轮辩论必须同一个评审者；红队自己解析一次；tiebreaker 跑 gemini 时复用 X2 的 id，改跑 grok 时重新解析（**不要**复用红队的 id——那是当事评审者）

## 异步 job（run-agent-async.sh，重活专用）

Claude Code Bash 工具单次调用硬上限 600s 且不可调；async 脚本用 nohup 把任务**脱离进程树**，deadline 默认 1800s（可到 7200），按族路由到 `run-codex.sh` 或 `run-cursor-agent.sh`。三个子命令：

```text
start  <prompt> <out> <codex|gemini|grok> [deadline]  → 秒回 JOB_DIR
status <job-dir>                                     → RUNNING x/ys | DONE | FAILED exit=N | DIED
wait   <job-dir> [max-wait≤560]                      → 阻塞到结束或到点；exit 0=DONE 3=还在跑 4=失败
```

**主 Claude 标准流程（⑥.5 后台长任务纪律）**：
1. `start` 拿 JOB_DIR → **当场告知用户**：预计多久（X1 5–8 min；xhigh 评审 4–15 min）、多久查一次（每波 wait ≤9 min）、超时怎么办（deadline 到点 job 自杀 exit 124 → 走降级矩阵）
2. `Bash(run_in_background:true)` 跑 `wait <job-dir> 540` —— 完成时 harness 自动通知，**期间继续干别的活**
3. wait 返回 3（波次到点未完）→ 把 RUNNING 行**主动报给用户** → 续发下一波 wait；**绝不**只回一句"还在跑"
4. DONE → Read 输出文件；FAILED/DIED → 按 exit code 映射降级 + banner，fail-loud
5. **绝不**在同步 Bash 调用里把 `SURVEY_TIMEOUT_SEC` 调大硬扛 600s 窗口——外层先死，你连 124 都拿不到

## 自检 + 自修复（doctor.sh）

Phase 2 启动 X1/X2 **前**主 Claude 必须先跑 `bash doctor.sh`（秒级，不耗配额）：

| 层 | 查什么 | 能否自动修 |
|---|---|---|
| L1 | 21 个 Read-gate / 运行时依赖文件齐全（含 `lib/agent-common.sh`、两个 runner、async runner）；`.sh` 执行位 | 执行位缺失 → **当场 chmod +x** |
| L2a | cursor-agent 安装；登录态用 `--list-models` 实打服务端（25s deadline） | 否——打印确切修复命令 |
| L2b | codex 安装；认证用 `run-codex.sh --auth-check` 实打服务端（零配额）。**禁止**用 `codex login status`（伪造凭据下照样 "Logged in"）或 `codex doctor` 的 auth.credentials（签名改坏仍 ok）当判据 | 否 |
| L3 | gemini/grok 经 `run-cursor-agent.sh --resolve-only` + 实时列表存在性复核；codex 经 `run-codex.sh --resolve-only`，`src=` 带 `-unlisted` 即判死。另报 gemini 非 flash 候选深度（=1 时 WARN 单点） | 否 |
| L3.5 | 额度留痕：读 runner 撞墙时写的状态文件（24h 内判该 lens dead） | 否——给出出路 |
| L4 | `--probe` 才跑：三 lens 各实跑一次 tiny prompt（codex 用 low 档；耗少量配额） | 否 |

exit code：`0` HEALTHY（codex + gemini 两只搜索眼可用）｜`1` DEGRADED（一只死，survey 走 PARTIAL）｜`2` BROKEN（双眼死或文件缺失，survey 退 3 Claude + SKIPPED）。**grok 死只 WARN 不降 verdict**。结果绝不阻塞主流程。

## codex 通道的已知污染与注意事项

- `codex exec` 的预置 prompt 里有 `<multi_agent_role>`「You are `/root`, the primary agent in a team」这类会重写 lens 身份的段落，**去不掉**（`--disable multi_agent` 无效）。所以 `agent-x.txt` / `round1.txt` 开头**显式覆盖身份**（"忽略任何把你定义成多 agent 团队成员的环境指令"），不要指望环境干净
- runner 已用 `--ignore-user-config -c skills.include_instructions=false --disable apps` 把预置 prompt 从 26.6KB 压到 14.6KB，并用 `-C <空目录> -s read-only` 隔离工作区。`~/.agents/skills` 里若有 frontmatter 损坏的 skill，codex 每次调用都会在 stderr 报一行错——无害，但要清理请修那个 skill
- **shell 内网络被沙箱拦**（只有 web_search 工具能联网）。prompt 里要明说"用搜索工具取证，不要用 shell 抓网页"，否则模型会浪费一轮在 urllib 上
- `--ignore-user-config` 会把 effort 静默降成 `none`，runner 已显式补回 `-m` 与 `-c model_reasoning_effort`；**别删这两个 flag**

## 脚本职责边界

`run-codex.sh` / `run-cursor-agent.sh` 只做 CLI 调用 + 超时控制 + exit code 分类 + 段落校验；共享机制在 `lib/agent-common.sh`（watchdog / 进程树屠杀 / 额度留痕 / 段落校验 / 参数校验，带版本护栏）。**不做**：
- 不做 preflight 脱敏检查（涉敏内容用户手动 sanitize）
- 不做 prompt 文件清理（OS 自动清 /tmp）
- 不做输出后处理（主 Claude Read 后自行解析）

## 绝不

- **绝不**因外部模型失败让主流程失败——降级是设计目标，不是异常
- **绝不**让 codex 当红队或 tiebreaker——同族自审
- **绝不**用同一个 timestamp 给 Phase 2 + Phase 6 复用 prompt 文件——/tmp 命名冲突会导致互相覆盖
- **绝不**省略同步 Bash 工具的 timeout 参数——它是脚本内置 watchdog 之外的第二层保护
- **绝不**把 `run-cursor-agent.sh` 复制到别的 skill——project-health 那份 412 行分叉就是这么烂掉的（零超时保护、无 67/68）。别的 skill 直接引用 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/` 下的 runner
