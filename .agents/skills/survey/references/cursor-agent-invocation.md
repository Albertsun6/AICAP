# cursor-agent Invocation Helper

> /survey 在 Phase 2（X1/X2 双异构搜索）和 Phase 6（主评审 + grok 红队第二评审 + Round 2/3 rebuttal + 事实核查 tiebreaker）调用 cursor-agent。所有调用细节集中在此，避免 phase 文件重复。

## 调用点一览（谁用哪个族）

| 调用点 | family | prompt 模板 | 文件名前缀 |
|---|---|---|---|
| Phase 2 Agent X1 | `gpt` | `prompts/agent-x.txt` | `survey-x1-` |
| Phase 2 Agent X2 | `gemini` | `prompts/agent-x2.txt` | `survey-x2-` |
| Phase 6 Round 1/2/3 **主评审** | `gpt`（替补链见下） | `prompts/round1.txt` / `round2-rebuttal.txt` | `survey-r1-` / `r2-` / `r3-` |
| Phase 6 Round 1 **红队第二评审**（one-shot） | `grok` | `prompts/round1.txt` + `prompts/round1-grok-prefix.txt` | `survey-r1g-` |
| Phase 6 事实 tiebreaker | `gemini`（回避/不可用时 `grok`） | `prompts/tiebreak.txt` | `survey-tb-` |

### 三族分工与替补链（2026-08-15 把 grok 接进来）

- **搜索眼**：X1=`gpt`、X2=`gemini`，不变。grok **不做搜索眼**——2026-08-15 实测它跑一个只有 2 问的玩具 prompt 就要 263s，完整搜索任务大概率撞 570s 同步窗口，会打破 Phase 2「四路同回合并发」的结构
- **主评审替补链**：`gpt → grok → gemini`。按推理档排：`cursor-grok-4.6-xhigh` 比只剩 `gemini-3.1-pro` 的 gemini 线更适合扛全文评审
- **红队第二评审**：固定 `grok`，**one-shot**（只在 Round 1 出场，不进 Round 2/3 rebuttal）。它是增量意见不是质量门禁，挂了不阻断主流程
- **tiebreaker 选族**：**必须与当轮主评审异族**，在存活族里**优先 `gemini`**；gemini 不可用、或触发利益回避（争议 source 来自 X2）时改用 `grok`。只有「所有非主评审族都不可用」才标 `tiebreaker: unavailable`
- **主评审已降到 grok 时**：红队第二评审**取消**（同族＝自我确认，没有增量），tiebreaker 用 `gemini`

**族不能乱配**：主评审与 tiebreaker **必须异族**，否则等于同一 lens 自我确认（见 `phases/06-debate.md` §降级）。

## 调用 4 硬点

1. **统一走脚本**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/run-cursor-agent.sh <prompt-file> <output-file> [gpt|gemini|grok]`，不内联 bash（避免变量展开 / ARG_MAX / 临时文件清理出错）。第三参数省略 = `gpt`
2. **prompt 必须用 Write 工具生成**到 `/tmp/survey-<前缀><unix-ts>-<4位随机>.txt`（前缀见上表，随机段可用 `$RANDOM` 或时间戳毫秒位）；**禁用 heredoc / cat 内联**。**X1 与 X2 并发跑，文件名前缀必须不同**；加随机段是因为用户常同开多窗跑 survey，秒级时间戳会跨窗口撞名互相覆盖
3. **同步/异步按任务重量二选一（都不许裸调）**：
   - **同步**（Phase 2 X1/X2 搜索、tiebreaker 等 <570s 的活）：Bash 工具 timeout 参数固定 `600000`（600s，这是工具硬上限，`BASH_MAX_TIMEOUT_MS` 有已知 bug 调不动）。脚本内层 watchdog 默认 **570s**（可用 `SURVEY_TIMEOUT_SEC` 覆盖但同步别调大），**内层必须比外层小**：否则外层先到期，脚本来不及返回自己的 124、主 Claude 也就分不清"超时"与"崩了"
   - **异步**（Phase 6 全文评审 Round 1-3、或 prompt >12KB 的任何调用）：**必须走 `run-cursor-agent-async.sh`**（见下方 §异步 job）。这类活在 xhigh 档常要 8-15 分钟，同步窗口装不下，硬塞的结果是超时白烧配额 + 整段丢失（2026-08-03 实测：同一个 24KB 评审 prompt，同步 570s 阵亡，async 563s 跑通出 8KB 结果——正好卡在同步窗口外）
4. **exit code → 降级路径完整映射**：

   | code | 含义 | 降级行为 |
   |---|---|---|
   | `0` | 成功 | Read 输出文件 `/tmp/survey-<前缀>output-<ts>.md` |
   | `64` | 参数错（含非法 family） | 主 Claude 修正调用，不是降级场景 |
   | `69` | not installed | + banner "cursor-agent not found" |
   | `124` | timeout >570s（脚本内置 watchdog 保证，任何环境都会触发） | + banner "cursor-agent timeout" |
   | `67` | **认证失效**（凭据过期/未登录，模型解析阶段就识破） | + banner "cursor-agent auth failure"，Reason 写 `auth failure`；**不回落、不降级重试**，先让用户 `cursor-agent login` |
   | `68` | **月度额度耗尽**（Other Models 池见底；`--list-models` 仍成功，只有真调用会撞） | + banner "cursor-agent quota exhausted"，Reason 写 `quota exhausted`。**必须与 67 分开**：修复动作完全不同（67 去登录；68 换族／等重置／显式开 on-demand）。撞墙会写状态文件供 doctor L3.5 读取 |
   | `65` | call failed（network / 其他） | + banner "cursor-agent error" |
   | `66` | empty output | + banner "cursor-agent returned empty" |

## 各调用点的降级路径

| 调用点 | 失败时 |
|---|---|
| Phase 2 Agent X1（gpt） | X2 活着 → 继续 3 路 + PARTIAL banner，**Phase 6 主评审按替补链改用 grok**（grok 也不可用才退 gemini）；X2 也挂 → 退 3 Claude + SKIPPED banner |
| Phase 2 Agent X2（gemini） | X1 活着 → 继续 3 路 + PARTIAL banner，**tiebreaker 改用 grok**（不再直接判 unavailable）；X1 也挂 → 退 3 Claude + SKIPPED banner |
| Phase 6 Round 1 主评审（gpt） | 按替补链换族**重试 1 次**（grok → gemini，计入 iteration bound）；替补也失败才跳过整个 Phase 6 + banner "HETEROGENEOUS REVIEW: SKIPPED" |
| Phase 6 Round 1 红队（grok） | **不阻断**——照常用主评审那一份 verdict 走判断矩阵，§metadata 标 `red-team: unavailable (<原因>)`。红队是增量意见不是质量门禁 |
| Phase 6 Round 2 | 停止后续辩论轮次，**仍执行第 7 步 tiebreaker**（tiebreaker 与主评审异族，主评审挂不代表它挂），再进人类裁决；带 metadata banner 标注"AI 辩论未跑满 3 轮" |
| Phase 6 Round 3 | 同 Round 2 |
| Phase 6 tiebreaker | 先按 §三族分工 的选族规则换族（gemini ↔ grok）；**所有非主评审族都不可用**才把事实性分歧原样转人类裁决 + metadata 标 `tiebreaker: unavailable`；**绝不**用与主评审同族顶替 |

完整矩阵见 `phases/02-research.md` §自动降级矩阵 与 `phases/06-debate.md` §降级。

## 调用模式（主 Claude 拼装步骤）

```text
1. Read 对应 prompt 模板（agent-x.txt / agent-x2.txt / round1.txt / round1-grok-prefix.txt / round2-rebuttal.txt / tiebreak.txt）
2. 注入 context（Brief 全文 / Source Quality 评分 / Phase 2.5 Reflection / Phase 5.5 Citation Health /
   Round 1-N 历史矩阵 / tiebreaker 的事实性分歧清单）
3. Write 到 /tmp/survey-<前缀>prompt-<unix-ts>.txt   （前缀见上表；X1/X2 不许同名）
4. Bash: bash run-cursor-agent.sh <prompt-file> <output-file> <family>，timeout=600000
5. Read 输出文件（如 exit 0）或 + banner（其他 exit code）
6. **结构校验（不能只看非空）**：X1/X2 输出必须含 `## Compressed Findings` 与 `## Source Inventory` 两段；Round 1 主评审与红队输出都必须含 verdict（Concur/Refine/Dissent）；tiebreaker 输出必须含 verdict 表。**缺段 = 按 exit 66（empty output）同样降级处理**——乱码或截断的输出被当成功用，比失败更糟。红队缺段按"红队不可用"处理（不阻断，标 metadata）
```

**Phase 2 的 X1/X2 必须在同一回合并发发出**（2 个 Agent 工具调用 + 2 个 Bash 调用），串行会白多花约 5 min。
**Phase 6 的 Round 1 主评审与红队同理**：同一回合发 2 个 async job（前缀 `survey-r1-` / `survey-r1g-`），串行会白多花 8-15 min。

## 模型选择（不钉版本，每族各跟最新最强）

脚本**每次运行时**跑 `cursor-agent --list-models`（约 1s，独立 20s deadline），按传入的 family 解析当前最强，不在任何文件里写死版本号：

| family | 规则 | 2026-08-15 实测解析结果 |
|---|---|---|
| `gpt` | `^gpt-` 且**必须** `-high`/`-xhigh`/`-extra-high` 结尾 | `gpt-5.6-sol-xhigh`（EFFORT=high → `gpt-5.6-sol-high`） |
| `gemini` | `^gemini-` 且**必须**含 `pro`（该族当前无 effort 后缀，故不要求后缀） | `gemini-3.1-pro` ⚠️ **全列表仅此一个非 flash 候选，是单点** |
| `grok` | `^cursor-grok-` 且**必须** `-high`/`-xhigh` 结尾（注意 id 带 `cursor-` 前缀） | `cursor-grok-4.6-xhigh`（EFFORT=high → `cursor-grok-4.6-high`） |

- 全族通排：`-fast`（插队优先队列＝额外计费，模型本身不更强）、`-none`/`-low`/`-medium`（低档）、`-codex`（编码专用）、`-mini`/`-nano`/`-lite`/`-flash`（小模型）、`-preview`/`-realtime`/`-audio`/`-image`/`-embed`/`-tts`（非通用推理形态）
- ⚠️ 这些排除项**必须带前导 `-` 按分段匹配**：裸子串 `mini` 会把 ge-**mini** 整族误杀（实测踩过，已写进 `test-model-selection.sh` 回归用例）
- **一切未知形态一律拒**（`gpt-6-preview` / 裸 `gpt-7`）——版本号大 ≠ 更适合调研，宁可退回上一代
- **`-max` 也排除**：实测 `gpt-5.6-sol-max` 跑同一评审任务要 **690s**，超过调用方 Bash 工具 **600000ms 的硬上限**（工具参数封顶）→ 必然超时、异构评审整段丢失；同任务 `xhigh` 只要 **314s**。要强上 max：`SURVEY_CURSOR_MODEL=gpt-5.6-sol-max`（并接受大概率超时）
- 比较：主版本 → 次版本 → effort 档（xhigh > high）→ 列表先出现者。**最后一条只是启发式**——Cursor 并未承诺列表顺序代表推荐度/能力，它只是同版同档多代号（`sol`/`terra`/`luna`）并存时的确定性 tie-break
- 取列表失败 / 超时 / 该族无候选 → 回落到该族 `FALLBACK_MODEL`（打 `WARN:` 到 stderr）。**非零退出但有部分输出**的列表一律丢弃，不从残缺列表里挑
- **未登录 / 凭据失效不在回落之列**（2026-08-30 改）：认证失效直接 `exit 67`。此前它被列为合法的静默回落触发条件，后果是 auth 故障被洗成"解析成功"——`--resolve-only` 照样 exit 0，doctor 据此报 HEALTHY，真调用再挂。fail-closed 见全局约束 ⑤
- 手动钉某个模型：`SURVEY_CURSOR_MODEL=<id>`（字符集校验 + **前缀必须匹配 family**，不匹配即忽略回自动解析——见下方"钉值跨族防串"）

### 档位配置（2026-08-03 加：按任务复杂度配 effort，不是全阶段无脑最强）

`SURVEY_CURSOR_EFFORT=high|xhigh`（缺省 xhigh）控制 gpt/grok 族自动解析的 effort **偏好**——版本仍优先，同版本内先挑偏好档、该档缺货自动落另一档（可用性优先，绝不因档位缺货整族失败）。gemini 族现无 effort 后缀不受影响；钉值（SURVEY_CURSOR_MODEL）不受影响。

| 调用点 | effort | 为什么 |
|---|---|---|
| Phase 2 X1/X2 搜索 | **`SURVEY_CURSOR_EFFORT=high`** | 检索型任务：搜索质量取决于检索行为不是推理深度，xhigh 徒增 2-3 min 且搜索在"四路并行等最慢"的关键路径上 |
| Phase 6 Round 1-3 主评审/辩论 | 缺省（xhigh） | 全管线最难的推理任务，深度就是质量；时间问题由 async job 解决，不靠降档 |
| Phase 6 Round 1 红队（grok） | 缺省（xhigh） | 同上；**且必须走 async**——grok 族基础延迟高（2026-08-15 实测：`cursor-grok-4.6-high` 跑一个 2 问玩具 prompt 就要 263s），同步窗口一定不够 |
| Phase 6 tiebreaker | 无关（gemini 无档；改用 grok 时按缺省 xhigh） | 事实核查靠联网，gemini-3.1-pro 是该族唯一候选 |
| doctor 探针 | 缺省 | 探针要验证"生产要用的模型调得通"，换便宜模型是验错对象 |
| `-max` 档 | 永远排除 | 690s 必超同步窗口；async 下想用请显式钉值并接受耗时 |

**主 Claude 必须做**：
1. 脚本把实际用的模型打到 stderr（`MODEL: <id> (family=<族>)`）并写进成功行（`OK: cursor-agent (<id>) wrote ...`）。报告 §调研 metadata 里的 `异构模型` **必须抄这些实际值**（X1 / X2 / R1 主评审 / R1 红队 各一），不许凭记忆写版本号。
2. **同一次调研内按"任务类"各解析一次**（2026-08-03 修订：X1 改 high 档后，Phase 6 不再复用 X1 的 id——档位配置见 §档位配置）：
   - Phase 2 X1/X2：各自解析一次（X1 带 `SURVEY_CURSOR_EFFORT=high`）
   - Phase 6 Round 1 主评审：自己解析一次（缺省 xhigh）；**Round 2/3 复用 Round 1 的 id**（`SURVEY_CURSOR_MODEL=<R1 实际 id>`）——同一份报告的多轮辩论必须同一个评审者（可复现性）
   - Phase 6 Round 1 红队（grok）：自己解析一次（缺省 xhigh）。它 one-shot，不存在复用问题
   - tiebreaker：族按 §三族分工 的选族规则定；跑 `gemini` 时复用 X2 的 id，改跑 `grok` 时自己解析一次（**不要**去复用红队的 id——那是评审者，复用等于让同一个实例给自己的争议做裁判）
   - **例外**：主评审按替补链降到 grok 时，Round 1 自己解析 grok 的 id，红队取消。**钉值跨族防串**：脚本会硬校验钉值前缀与 family 匹配，不匹配一律忽略并打 WARN 重新解析（防 export 后忘 unset 导致 tiebreaker 偷偷跑成 GPT）——所以钉错不会串族，但会浪费一次解析，主 Claude 仍应按族传对。

> 2026-08-15 实测：`gpt`→`gpt-5.6-sol-xhigh`，`gemini`→`gemini-3.1-pro`，`grok`→`cursor-grok-4.6-xhigh`。三族均实测可联网搜索并给出真实 URL。
> ⚠️ 两条要盯着的结构性风险：① gemini 族在 Cursor 里**只剩 `gemini-3.1-pro` 一个非 flash 候选**，它一下架，X2 与默认 tiebreaker 同时哑火（这正是把 grok 接进替补链的直接原因）；② grok 族基础延迟明显高于另两族（263s 玩具 prompt 实测），只安排在 async 调用点上，别放进任何同步窗口。

## 异步 job（run-cursor-agent-async.sh，重活专用）

Claude Code Bash 工具单次调用硬上限 600s 且不可调；async 脚本用 nohup 把任务**脱离进程树**，deadline 默认 1800s（可到 7200），会话窗口关了都不影响。三个子命令：

```text
start  <prompt> <out> [family] [deadline]  → 秒回 JOB_DIR
status <job-dir>                           → RUNNING x/ys | DONE | FAILED exit=N | DIED
wait   <job-dir> [max-wait≤560]            → 阻塞到结束或到点；exit 0=DONE 3=还在跑 4=失败
```

**主 Claude 标准流程（⑥.5 后台长任务纪律，逐条对应）**：
1. `start` 拿 JOB_DIR → **当场告知用户**：预计多久（xhigh 评审 8-15 min）、多久查一次（每波 wait ≤9 min）、超时怎么办（deadline 到点 job 自杀 exit 124 → 走降级矩阵）
2. `Bash(run_in_background:true)` 跑 `wait <job-dir> 540` —— 完成时 harness 自动通知，**期间继续干别的活**（写报告别的章节、跑 Citation Health）
3. wait 返回 3（波次到点未完）→ 把 RUNNING 行**主动报给用户**（已跑多久/上限多少）→ 续发下一波 wait；**绝不**只回一句"还在跑"
4. DONE → Read 输出文件做结构校验（同 §调用模式第 6 步）；FAILED/DIED → 按 exit code 映射降级 + banner，fail-loud
5. **绝不**在同步 Bash 调用里把 `SURVEY_TIMEOUT_SEC` 调大硬扛 600s 窗口——外层先死，你连 124 都拿不到

## 自检 + 自修复（doctor.sh）

Phase 2 启动 X1/X2 **前**主 Claude 必须先跑 `bash doctor.sh`（秒级快检，不耗配额），把环境故障从"调研中途降级 banner"前置成"开跑前已知情"：

| 层 | 查什么 | 能否自动修 |
|---|---|---|
| L1 | 17 个 Read-gate 依赖文件齐全；`.sh` 执行位 | 执行位缺失 → **当场 chmod +x**（`[FIXED]`） |
| L2 | cursor-agent 安装；**登录态用 `--list-models` 实打服务端判定**（25s deadline，不烧配额），失败按 auth / 网络 / 未识别三档分流，未识别档 fail-closed | 否——打印确切修复命令（install / `cursor-agent login`） |
| L3.5 | **月度额度**：读 `run-cursor-agent.sh` 撞墙时写的状态文件（`${SURVEY_STATE_DIR:-~/.cache/survey}/quota-state`）。**不能靠解析模型列表**——2026-08-30 实测 Other Models 池见底时 `--list-models` 仍 exit 0 返回 206 行，L1–L3 全绿。24h 内的留痕判该族 dead（fail-closed），过期留痕自动清理 | 否——给出"换族／等重置／开 on-demand"三条出路 |
| L3 | gpt+gemini 双族模型解析（走 `run-cursor-agent.sh --resolve-only <family>`，**复用生产解析逻辑**，杜绝两处漂移）；落到 fallback 时再查 fallback 是否仍在实时列表 | 否——提示跑 `test-model-selection.sh` / 更新 `FALLBACK_MODEL` |
| L4 | `--probe` 才跑：两族各实跑一次 tiny prompt（并发，各限 180s；耗少量配额） | 否 |

exit code：`0` HEALTHY（含已自动修复/纯 WARN）｜`1` DEGRADED（一只 lens 死，survey 走 PARTIAL）｜`2` BROKEN（双 lens 死，survey 退 3 Claude + SKIPPED）。**结果绝不阻塞主流程**，降级矩阵照常生效；非 0 时把 doctor 给的修复建议原样转告用户。

`--resolve-only` 契约（doctor 依赖）：`bash run-cursor-agent.sh --resolve-only [family]` → stdout 打裸模型 id、stderr 照常打 `MODEL:` 行（含 fallback 时的 `WARN:`），exit 0；不发起正式调用、不耗配额。回归用例见 `test-model-selection.sh` §运行时 8。

## 脚本职责边界

`run-cursor-agent.sh` 只做 cursor-agent CLI 调用 + 超时控制 + exit code 分类。**不做**：
- 不做 preflight 脱敏检查（涉敏内容用户手动 sanitize）
- 不做 prompt 文件清理（OS 自动清 /tmp）
- 不做输出后处理（主 Claude Read 后自行解析）

## 绝不

- **绝不**因 cursor-agent 失败让主流程失败——降级是设计目标，不是异常
- **绝不**用同一个 timestamp 给 Phase 2 + Phase 6 复用 prompt 文件——/tmp 命名冲突会导致互相覆盖
- **绝不**省略 Bash 工具的 timeout 参数——它是脚本内置 watchdog 之外的第二层保护（防脚本本身出 bug）
