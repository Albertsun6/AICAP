# AICAP 使用说明（项目专属）

> 面向人的操作手册。**只收录在本仓库里才生效的东西**；全局约定看 `~/.claude/USAGE.md`。
> 能力本身的定义在 `.rulesync/`（SSOT），skill 清单在 `SKILLS.md`。
>
> 最近更新：2026-07-30

## 速查

| 命令 | 干什么 |
|---|---|
| `pnpm run ai:generate` | 从 `.rulesync/` 生成四个工具的产物（改完 SSOT 必跑） |
| `pnpm run ai:check` | generate 后比对，有漂移就非零退出（CI drift gate 同款） |
| `pnpm run ai:check-skills` | skill 门禁：断链 / 索引一致性 / 硬编码路径 |
| `pnpm run ai:check-orphans` | 查「入库了但 generate 不再产出」的孤儿产物（drift gate 的盲区） |
| `pnpm run ai:eval:trigger` | skill 触发准确度 eval，**走 Claude Code 订阅，不需要 API key** |
| `pnpm run ai:eval:arena` | **竞技场 eval**：真跑 `claude -p`，看全 SSOT skill 同场竞争时实际触发了谁 |
| `pnpm run ai:eval:trigger:api` | 同上，但走 promptfoo + `ANTHROPIC_API_KEY`（CI 用这条） |
| `pnpm run setup:skills` | 把 SSOT skills 软链到 `~/.claude/skills/`（幂等） |

---

## 孤儿产物检查（`scripts/check-orphan-products.py`）

**是什么**：drift gate（`generate && git diff --exit-code`）有个结构性盲区——它只能
发现**内容不一致**，发现不了**整棵树被遗弃**。generate 从不触碰死树，所以它永远不会
diff，只会随 SSOT 变更无声漂移。

这不是假想：rulesync 8.18 → 16.2 升级时，codexcli 的 skill 输出位置从 `.codex/skills/`
改到了 `.agents/skills/`。升级那次 commit 新增了 `.agents/`（198 个文件，还专门写了
说明），却没人发现 `.codex/skills/` 的 199 个文件从此变成死的——当时内容还一样，
但 SSOT 一改就开始分叉，而 CI 全绿。

**怎么用**

```bash
pnpm run ai:check-orphans                                  # 有孤儿则非零退出（CI 用）
python3 scripts/check-orphan-products.py --list            # 只列出，不因此失败
```

原理：把 SSOT 生成到临时目录（`rulesync generate -o <tmp>`），拿「新鲜产出的文件集」
当真值，比对版本控制里落在同样产物根下的文件。入库有、新鲜产出没有 = 孤儿。
换输出路径、砍掉某个 feature、有人手工往产物目录塞文件，三种都能抓到。

它依赖网络（`npx rulesync@<pin 的版本>`），所以**不放进 `check-skills.py`**——
那个门禁是纯静态的、跑得飞快，不该被拖成分钟级。

**误报怎么办**：住在产物根下但不是 rulesync 产出的手写文件（如
`.github/workflows/`），加进脚本里的 `ALLOWLIST` 并写明理由。

**怎么撤**：删 `scripts/check-orphan-products.py`，去掉 `package.json` 的
`ai:check-orphans`，删 workflow 里那一步。

---

## 依赖与 `pnpm-workspace.yaml`（clone 下来先看这条）

生成器 pin 在 `rulesync@16.2.0`（`package.json` + CI workflow 两处，升级时要一起改）。

仓库根有个 `pnpm-workspace.yaml`，**它是必需配置，不是噪音**：

```yaml
allowBuilds:
  tldjs: false
```

pnpm 11 遇到带 build script 的依赖会征询一次，答过就不再问；**没答的话每次
`pnpm run <任何脚本>` 都会以 `ERR_PNPM_IGNORED_BUILDS` 退出 1**（pnpm 在跑 script
前会做 depsStatusCheck）。`tldjs` 经 `rulesync → fastmcp → mcp-proxy → pipenet`
传进来，postinstall 是联网更新 public suffix list——generate 用不到，且 postinstall
是供应链攻击常见入口，所以答 `false`。

> 这个文件曾被误判为「pnpm 生成的占位垃圾」写进 `.gitignore` 还顺手 `rm` 掉，
> 结果本地所有 `pnpm run` 坏了一个多月没人发现（CI 用 `npx -y rulesync@…`，
> 不跑 `pnpm install`，所以一直是绿的，掩盖了本地的坏）。**别再 ignore 它。**

若 `pnpm install` 报 `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`，是它要重建
`node_modules` 但拿不到确认——`CI=true pnpm install` 即可（一次性）。

---

## skill 门禁（`scripts/check-skills.py`）

**是什么**：防止 skill 之间的引用悄悄断掉、`SKILLS.md` 索引悄悄漂移、SSOT 里悄悄混进只在某台机器上成立的路径。

**怎么用**

```bash
pnpm run ai:check-skills          # 本机全量（含 ~/.claude 全局层）
python3 scripts/check-skills.py --ssot-only        # 只查仓库内容，CI 用这个
python3 scripts/check-skills.py --strict-global    # 把全局层的收录差异也当错误
```

分两层：**SSOT 层**只看仓库、CI 可跑、违规一律红；**全局层**需要本机 `~/.claude/`，CI 上自动跳过，断链 symlink 是红、收录差异是黄（队友机器上的本地 skill 天然不同，不该因此挡 PR）。

规则表见 `.rulesync/rules/skills.md`（S1–S9 / G1–G5）。

其中 **S9**（description ≤1024 字符）防的是一类静默失效：你发现某 skill 漏触发 → 在 description 末尾追加触发词 → 总长超限 → **新加的那句正好在尾部被截掉** → 以为修好了，实际模型压根没看到。官方文档那句 *Put the key use case first* 就是在暗示这件事。

当前最长的是 `learning-loop` **496 字符 = 上限的 48%**，无人触碰 800 警戒线——它原本 891 字符（87%），
精简时把实现细节移进正文、23 个触发词一个没删。门禁现存的 3 个警告全是 S5（指向「已知缺失的能力」），与长度无关。

**门禁自己怎么被验证**：`python3 scripts/test-check-skills.py` —— 为每条规则造一个合成违规，断言必须红在正确的规则码上；再断言干净基线绿、合法用法不误报。CI 里**先跑这个，再跑门禁**：一个坏掉的门禁会安静地放行一切。

**怎么撤**：删 `scripts/check-skills.py`、`scripts/test-check-skills.py`，去掉 `package.json` 的 `ai:check-skills`，删 `.github/workflows/ai-config-drift.yml` 里那两步。SKILL.md 里的 `invokes:` / `recommends:` 字段留着无害（rulesync 会剥掉，不进任何产物）。

---

## 调用图元数据：`invokes` / `recommends`

写在 `.rulesync/skills/<name>/SKILL.md` 的 frontmatter：

```yaml
invokes: ["survey"]                              # 本 skill 会让对方真正跑起来
recommends: ["install-skill", "skill-creator"]   # 只是指向对方，不触发
```

**实测**：rulesync 会把**未知** frontmatter 字段从产物里剥掉，所以这两个字段只活在 SSOT——不进任何工具的上下文，也不会让 drift gate 变红。

> ⚠️ 但**目标工具的官方字段**不属于「未知」，前提是写在 `claudecode:` 块里。`when_to_use` / `argument-hint` / `user-invocable` 写在顶层会被静默剥掉，写在块内则完整保留（引入于 rulesync 8.32.0，本仓库 pin 16.2.0）。我为此误判过一次——见 `.rulesync/rules/skills.md`。

为什么必须显式声明而不是 grep 正文：`plan-ceo-review` 里的 "Correctly **diagnose** peacetime vs wartime" 会被当成调用 `diagnose` skill，示例输出里的 skill 清单也全是噪音。

---

## 触发 eval（`promptfoo/trigger-eval.yaml`）

**是什么**：把 Claude Code 实际放进上下文的那份 `name + description` 原样喂给模型，问「这句话该触发哪个 skill」。20 条用例：10 条基础（7 正例 + 3 邻近负例）+ 10 条**刁钻组**，后者专挑描述边界糊的近邻。

**测的是描述的可分辨性**——唯一我们能改的变量。**不是** Claude Code 真实触发链路的复刻（没有系统提示、没有会话历史、没有工具集），所以它是代理指标，用来回答「改了 description 之后区分度是变好还是变差」。

**怎么用（本机，不需要 API key）**

```bash
pnpm run ai:eval:trigger          # 全部 10 条
python3 promptfoo/run-trigger-eval.py -k 提交    # 只跑描述含"提交"的
python3 promptfoo/run-trigger-eval.py -v         # 失败时打印模型原始输出
```

[run-trigger-eval.py](promptfoo/run-trigger-eval.py) 用 `claude -p` 跑，走的是**你已经在付费的 Claude Code 订阅**，且用的就是 Claude Code 真实路由时用的那个模型——比打 API 更贴近要测的链路。用例、prompt 模板、断言全部读同一份 `trigger-eval.yaml`，不维护第二套。约 5 秒一条。

> **踩过的坑**：Claude Code 默认会把**本机真实的 skill 清单**注入上下文，模型会拿它来回答，测出来就变成"它记不记得本机装了什么"而不是"这份索引可不可分辨"。实测：不加 `--disable-slash-commands` 时，它会答出索引里根本没有的 `report-to-audio`。runner 已经默认加了这个开关，别删。

**怎么用（CI / 有 API key 时）**

```bash
export ANTHROPIC_API_KEY=...
pnpm run ai:eval:trigger:api      # promptfoo 路径
```

索引 `promptfoo/skill-index.txt` 是生成物（已 gitignore）——入库会变成一份会过期的快照。

CI 上没配 `ANTHROPIC_API_KEY` 时整个 job 跳过，并打一条 `::warning::` 说明本次 PR 的触发准确度**没有**被验证（不静默变绿）。GitHub runner 上没有 Claude Code 订阅，所以 CI 只能走 API 那条。

**基线**：2026-07-29，**20/20**。

扩到 20 条时它第一次真正指了路：`find-skills` 那条红了。排查出两层原因——

1. 我原来那句用例有歧义（可读成「我要做这件事」而非「我在找 skill」），**是题出错**；
2. 顺着查下去才发现真问题：`find-skills` 的真实边界（走 `npx skills` CLI、只查 skills.sh 单一注册表、装完即用不进 SSOT）写在了 `SKILLS.md` 和 `search-online-skills` 的对比表里，**唯独没写进它自己的 description**——而 description 是模型唯一看得见的东西。补进去后三者互斥、转绿。

**教训**：eval 红了先排除「题出错」，再怪被测对象。这跟 runner 那次同源——第一次红也是 runner 自己的洞。

**怎么撤**：删 `promptfoo/trigger-eval.yaml` + `promptfoo/build-skill-index.py`，去掉 `package.json` 的 `ai:eval:trigger`，把 workflow 里的 `has-api-key` / `prompt-eval` 两个 job 删掉。

---

## skill 作用域：怎么让一个 skill 只在某个项目里出现

**不需要"识别项目"**——Claude Code 按 skill 文件**住在哪**决定作用域：

| 层级 | 位置 | 作用域 |
|---|---|---|
| Personal | `~/.claude/skills/<name>/` | 所有项目 |
| Project | `<project>/.claude/skills/<name>/` | **仅该项目** |

`pnpm run ai:generate` 本来就把 skill 写进本仓库的 `.claude/skills/`（那正是 Project 层），
`setup:skills` 再额外软链到全局。**少建一条软链，它就自动变成项目级。**

### 三档用法

**① 只服务本仓库** → SSOT frontmatter 写 `scope: project`

```yaml
name: aicap-commit
scope: project
```

然后 `pnpm run setup:skills`——脚本据此跳过全局软链，并**回收**本仓库先前建过的那条。
门禁 G5 负责对账：声明了项目级却还在 `~/.claude/skills/` 就报错。

**② 服务别的仓库** → 把目录搬进那个仓库的 `.claude/skills/`，随它的版本控制走。
当前 `zupu-ship` / `zupu-spec-sync` 已迁入 `族谱/zupu-cloud/`。

**③ 没有可归属的项目** → `~/.claude/settings.json` 的 `skillOverrides` 降档：

```json
"skillOverrides": { "fedex-tracker": "name-only" }
```

四档：`on`（名字+描述）/ `name-only`（**只有名字，描述不进上下文**）/
`user-invocable-only`（对模型隐藏，`/` 菜单还在）/ `off`（全隐藏）。
`/skills` 菜单里按空格键也能切。它比 frontmatter 的 `disable-model-invocation` 更合适：
不改 SKILL.md、可按项目在 `.claude/settings.local.json` 里单独覆盖、四档而非两档。

### ⚠️ 别用 `paths` 做仓库隔离

官方文档：*loads the skill automatically **only when working with files matching the
patterns***——匹配的是**会话中正在操作的文件**，不是当前仓库。

实测（探针 + 对照组）：`**/AICAP/**`、`**/AICAP`、绝对路径、仓库相对路径**全都不匹配**，
只有 `**` 匹配；而读过一个 `.swift` 后，`paths: ["**/*.swift"]` 的 skill 立刻出现。

拿它当仓库作用域会**漏触发**：你说"帮我提交这次改动"时若还没读过匹配文件，skill 不出现。
它只适合本来就由文件类型驱动的 skill。

---

## 两套 eval 的分工（都要保留）

| | `ai:eval:trigger` | `ai:eval:arena` |
|---|---|---|
| 测什么 | 模型**说**该触发哪个（元认知问询） | 模型**实际**触发了谁（行为测量） |
| 环境 | 手工拼的 skill 索引 | 真跑 `claude -p`，全 SSOT skill 同场竞争 |
| 成本 | ~5 秒/条 | 数十秒/条（跑完整 agent 轨迹） |
| 用途 | 改完 description 快速防回归 | 定期验真、出混淆矩阵 |

**模型「说」它会触发什么 ≠ 它实际触发什么**，所以两套都要。

### 竞技场 eval 为什么不直接用官方 skill-creator

用它之前先做了异构评审（GPT-5.6 + Gemini-3.1-pro 独立评审，判断矩阵见
[docs/reviews/skill-creator-异构评审-2026-07-29.md](docs/reviews/skill-creator-异构评审-2026-07-29.md)）。
两只眼独立一致地指出它的测量层有几处会产生**假绿**的缺陷，最关键的一条是
**它一次只把一个 skill 注入测试环境**——孤岛评分会奖励「贪婪型描述」（自己更容易
被触发，代价是抢邻居的活），而它测不到这个代价。我们 24 个 skill 里恰恰有好几组
近邻，用孤岛工具优化很可能一个个分数都变好、整体路由却变差。

所以只借它的**测量思路**（真跑看行为，而不是问模型），把孤岛换成竞技场。
`run-arena-eval.py` 里逐条注明了避开的缺陷。

**候选集怎么受控**：`~/.claude/skills` 的 personal 层覆盖 project 层，所以 SSOT skill
本来就在场；临时项目里用 `skillOverrides` 关掉 9 个非 SSOT 本地 skill + `disableBundledSkills`。
**不能**用空的 `CLAUDE_CONFIG_DIR` 做隔离——订阅凭据也存在那个目录，实测直接 `Not logged in`。

---

## MCP 空闲自动关闭

`.rulesync/mcp.json` 里的 github server 套了 `scripts/mcp-idle-wrapper.py`：它在
Claude Code 与真正的 MCP server 之间转发 stdio，**空闲 30 分钟后自动关掉 server**
（`MCP_IDLE_TIMEOUT`，单位秒）。省的是一个常驻的 node 进程。

```json
"command": "python3",
"args": ["scripts/mcp-idle-wrapper.py", "npx", "-y", "@modelcontextprotocol/server-github"],
"env": { "MCP_IDLE_TIMEOUT": "1800" }
```

**用仓库相对路径，不要写死绝对路径**——这仓库搬过一次家，写死的路径全失效过（见 S7）。
它依赖 MCP client 以仓库根为 cwd 启动 project MCP。路径写错时 server 直接起不来、
客户端报 MCP 连接失败，是显性失败不会静默降级。

**怎么撤**：把 `.rulesync/mcp.json` 里 github 的 `command` 改回 `npx`、`args` 去掉
wrapper 那两项、删掉 `MCP_IDLE_TIMEOUT`，然后 `pnpm run ai:generate`。

> 这个脚本此前写了两个多月但**一直没接上**：mcp.json 用的是直接 `npx`，三份生成配置里
> wrapper 引用数都是 0，唯一引用它的是 `.rulesync/hooks.json` 里一条 `Stop` hook——
> 而那条 hook 四个 target 全部 `Skipped (not supported)`，产物里 0 处，从未执行过。
> 现在真接上了，`.omm` 里那句「配合 mcp-idle-wrapper 做空闲自动关闭」才名副其实。

---

## 「已知缺失的能力」这一节是干嘛的

`SKILLS.md` 末尾有一节登记**被引用但不存在**的能力（当前：`deep-research`、`plan-design-review`、`design-review-lite`）。

登记 ≠ 修好：门禁会把指向它们的引用报成 **WARN**（不挡 CI，但每次都提醒），而**没登记**的断链仍然是红。这样缺口是显式留痕的，而不是把引用悄悄删掉当没发生过。补上其中任何一个之后，把它从该节移到对应章节即可。
