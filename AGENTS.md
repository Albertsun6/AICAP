# 项目总则（SSOT 根规则）

> 这是**单一事实来源**。所有工具（Claude Code / Cursor / Codex / Copilot）的项目级指令都从这里生成，
> **不要直接改生成出来的 CLAUDE.md / AGENTS.md / .cursor/rules——改这里，然后 `rulesync generate`**。
> 原则：手写、分层、保持小。本文件超过 ~200 行就拆到 `.rulesync/rules/<topic>.md`（路径作用域）。

## 项目约定（与技术栈无关，长期有效）

- 目录组织：按 feature 组织，不按文件类型；相关文件就近放置
- 命名：kebab-case 文件名；公共标识符语义化、可验证
- 改动前先确认本项目的构建/测试方式（见下"项目特定约定"），不要臆测工具链
- 提交前必须本地把 lint + test 跑通再提交

### 项目特定约定（技术栈待定 — TODO，勿留空猜测）

> 团队尚未确定主技术栈。确定后在此补全并删除本提示行：
> 主语言/框架、包管理器、确切的 lint 命令、test 命令、
> "如何本地验证一个改动是对的"的标准步骤。
> 在补全前，AI 应主动询问构建/测试方式，而不是假设。

## 工作方式（对所有 AI 工具生效）

- 改动前先读相关文件与本规则；不臆造不存在的 API / 文件
- 小步提交，每个改动可独立回滚；不在一个提交里混多个无关变更
- 不确定时先问，不要静默做出影响范围大的决定
- 不把 secrets 写进任何被提交的文件；密钥走 user-scope MCP 配置或环境变量

## 这套体系怎么用（贡献者必读）

1. 改能力 = 改 `.rulesync/` 下的源文件（rules / skills / subagents / commands / mcp）
2. 跑 `pnpm run ai:generate`（= `rulesync generate --targets "*" --features "*"`）
3. 把**源文件 + 生成产物一起提交**（生成物纳入版本控制，CI drift gate 才能比对）
4. PR 只评审 `.rulesync/` 源；生成物视为构建产物，diff 仅用于核对

# skill 作者约定（路径作用域规则）

> 只在改 `.rulesync/skills/`、`SKILLS.md` 或门禁脚本时进入上下文。
> 门禁：`python3 scripts/check-skills.py`（CI 自动跑 SSOT 层，本地额外跑全局层）。

## 声明调用图，不要靠 grep 推断

一个 skill 引用另一个 skill 时，**在 frontmatter 里显式声明**：

```yaml
invokes: ["survey"]                       # 本 skill 会让对方真正跑起来（模型硬调用）
recommends: ["install-skill", "skill-creator"]  # 只是指向对方，不触发它
```

- `invokes` —— 运行时真的把对方拉起来执行。
- `recommends` —— 给人的路由（"这事该用 X"）、复用对方的规范、或明确排除。**不**触发对方。

为什么不靠正文 grep：假阳性压倒真信号。`plan-ceo-review` 正文里的
"Correctly **diagnose** peacetime vs wartime" 会被当成调用 `diagnose` skill；
`install-skill` 的示例输出里列着一串 skill 名，也全是噪音。反过来还有假阴性——
自然语言别名（"做个仓库体检" → `project-health`）grep 根本抓不到。

这两个字段**只存在于 `.rulesync/` 源**：rulesync 会把**未知** frontmatter 字段
从产物里剥掉（`video-hyperframes` 的 20 个自定义字段、`xcuitest-skill` 的 `metadata`
都是这样没的）。所以声明调用图不会进任何工具的上下文，也不会让 drift gate 变红。

## ⚠️ 目标工具的官方字段要写在 `claudecode:` 块里，不是顶层

被剥掉的只有**未知**字段。Claude Code 自己的官方字段（`when_to_use`、`argument-hint`、
`user-invocable`、`disable-model-invocation`、`paths` …）rulesync 是支持的，但**必须
写在 `claudecode:` 块内**——写在顶层一样会被当成未知字段静默剥掉：

```yaml
# ✅ 生效
claudecode:
  when_to_use: 用户描述一个复现不了的偶发问题、或性能突然变差时。

# ❌ 静默丢失，generate 照样 exit=0
when_to_use: 用户描述一个复现不了的偶发问题、或性能突然变差时。
```

这个坑我踩过一次：因为顶层写法被剥掉，就断定「rulesync 不支持 `when_to_use`」，
还准备给上游提 issue——实际上上游早在 #1629 就修好了，是写法错了。
判断「某个字段能不能用」时，**两种写法都要试过再下结论**。

注意它只对 Claude Code 生效（毕竟写在 `claudecode:` 块里），其余 target 的产物不会有
这个字段——跟下面 `disable-model-invocation` 的跨工具不对称是同一回事。
（rulesync 里 `qwencode` 也支持 `when_to_use`，但本仓库不生成那个 target，故与我们无关。）

### `when_to_use` 会被**拼接进** description，不是独立槽位

用之前先知道它的真实语义。Claude Code 官方文档原文：

> `when_to_use` — Additional context for when Claude should invoke the skill, such as
> trigger phrases or example requests. **Appended to `description` in the skill listing**
> and counts toward the 1,536-character cap.

二进制里的 schema 自述同样是 *"Becomes part of the tool description."*，实测也一致——
注入唯一标记后，模型看到的是 `<description>` + `" - "` + `<when_to_use>` 一个字符串。

由此得到三条约束：

1. **对 Claude Code，触发词写哪边等价**（同一个字符串、同一个位置）。所以别指望
   「拆成两个字段」本身能改善路由——它改善的只是 SSOT 的可读性。
2. **不要把触发词从 `description` 搬走**。`.cursor/skills/`、`.github/skills/`、
   `.agents/skills/` 各有一份完整 24 个 SKILL.md，且 `description` 是它们**唯一**的
   路由字段（没有 globs/applyTo 接住）。实测搬移让这三份各丢 44%（survey 81%、
   learning-loop 75%）。要用就**只追加不搬移**，或写一个后处理把它拼回另外三个 target。
3. **`when_to_use` 不属于 Agent Skills 开放标准**。官方 skill-creator 的
   `quick_validate.py` 白名单只有 `{name, description, license, allowed-tools,
   metadata, compatibility}`，带上它会报 `Unexpected key(s)`。本仓库 CI 不跑那个
   validator，所以这不是当前的运行成本，但要知道是在用 Claude Code 私有扩展。

两个上限的准确出处（都核实过，别再凭记忆）：**1024** 来自 Agent Skills spec
（agentskills.io/specification，官方 validator 按它校验）；**1536** 是 Claude Code 的
`skillListingMaxDescChars` 默认值，管的是 `description + when_to_use` 合并后的长度
（CHANGELOG v2.1.105「raised the listing cap from 250 to 1,536」）。

还有一个**共享**预算：`skillListingBudgetFraction` 默认 `0.01`，即模型上下文窗口的 1%
（是 **token** 不是字符——我算错过一次）。超了之后「最少用的 skill 的 description 会被
丢弃、只列名字」。实测证明机制存在：把它压到 `0.0005` 后 40 个 skill 全部只剩名字；
默认值下没有这种丢弃。**S9 目前只量 `description`、不解析 `when_to_use`**，所以一旦
开始用这个字段，1536 那条合并上限就没人执行了——要用先补门禁。

## 跨工具语义不对称：`disable-model-invocation` 只对 Claude Code 生效

想把一个 skill 改成"只能人手打 `/name`、模型不许自动触发"，写法是：

```yaml
claudecode:
  disable-model-invocation: true
```

注意**它只影响 Claude Code**。`codexcli` 侧只有 `short-description`，没有等价的调用控制；
Cursor / Copilot 侧同理。也就是说同一个 skill 会出现：

| target | 模型能否自动触发 | description 是否进上下文 |
|---|---|---|
| claudecode（设了该字段） | 否 | 否 |
| codexcli / cursor / copilot | 是（照常） | 是 |

**不要假设"关掉自动触发"是跨工具一致的行为。** 只在"这个能力本来就只在
Claude Code 里用"时才依赖它；否则跨工具行为会分叉而没人发现。

## 作用域：靠 skill **住在哪**，不是靠字段

Claude Code 按 skill 文件所在位置决定作用域，所以「只在某个项目可见」不需要任何
识别机制，也不需要新字段：

| 层级 | 位置 | 作用域 |
|---|---|---|
| Personal | `~/.claude/skills/<name>/` | 所有项目 |
| Project | `<project>/.claude/skills/<name>/` | **仅该项目** |
| Plugin | `<plugin>/skills/<name>/` | 启用该 plugin 处 |

`rulesync generate` 本来就把 skill 写进本仓库的 `.claude/skills/`——那正是 Project 层。
`setup:skills` 再额外把它们软链到全局。**少建一条软链，它就自动变成项目级。**

用法：在 SSOT frontmatter 写 `scope: project`，然后 `pnpm run setup:skills`——脚本据此
跳过全局软链，并回收本仓库先前建过的那条。门禁 G5 负责对账。`scope` 同样被 rulesync
从产物里剥掉，所以脚本读的是 `.rulesync/` 源。

服务于**别的**仓库的 skill（如 `zupu-*`），直接把目录搬进那个仓库的 `.claude/skills/`，
随它的版本控制走。

### ⚠️ `paths` 不是仓库作用域——别拿它做这件事

官方文档原文：*Glob patterns that limit when this skill is activated. When set, Claude
loads the skill automatically **only when working with files matching the patterns**.*

匹配的是**会话中正在操作的文件**，不是当前仓库。实测确认（探针法，对照组无 `paths` →
可见）：`**/AICAP/**`、`**/AICAP`、绝对路径、仓库相对路径全都不匹配，只有 `**` 匹配；
而读过一个 `.swift` 文件后，`paths: ["**/*.swift"]` 的 skill 立刻出现。

所以 `paths` 只适合**本来就由文件类型驱动**的 skill（`xcuitest-skill` 之类）。拿它当仓库
隔离用会引入漏触发：你说「帮我提交这次改动」时若还没读过任何匹配文件，skill 不会出现。

### 第三档：`skillOverrides`（settings，不改 SKILL.md）

没有可归属项目的 skill（个人工具、或它服务的项目已不在本机）用这个降档。写在
`~/.claude/settings.json` 或项目的 `.claude/settings.local.json`，`/skills` 菜单按空格也能切：

| 值 | 模型看到 | `/` 菜单 |
|---|---|---|
| `on` | 名字 + 描述 | 有 |
| `name-only` | 只有名字（描述不进上下文） | 有 |
| `user-invocable-only` | 隐藏 | 有 |
| `off` | 隐藏 | 隐藏 |

它比 `disable-model-invocation` 更适合做这件事：不改 SKILL.md（不污染 SSOT）、可按项目
覆盖、四档而非两档。

## 门禁在查什么

SSOT 层（CI 强制，违规 = 红）：

| 规则 | 内容 |
|---|---|
| S1/S2 | `name` 与目录名一致；`description` 非空 |
| S3/S4 | `SKILLS.md` 收录集合与实际目录双向一致；章节标题里的计数属实 |
| S5 | `invokes` / `recommends` 的每个目标都能解析到已声明的 skill（断链即红） |
| S6 | 被 `invokes` 指向的 skill 不得设 `disable-model-invocation`（模型调不动它） |
| S7 | SSOT 正文不得写死本机路径（`/Users/...`、`~/Desktop/...`）；`~/.claude` 除外 |
| S8 | `scope` 只认 `global`（默认）与 `project`；拼错必须红，否则会静默退化成全局 |
| S9 | `description` ≤ **1024** 字符（>800 报 WARN）。两个上限取严者：1024 是 Agent Skills 开放标准 spec，1536 是 Claude Code 对 `description` + `when_to_use` 的 listing 截断阈值。**超出静默丢失**——不报错、generate 照常 exit=0，而丢掉的往往正是你最后追加的触发词 |
| S10 | 正文 / `description` 里以 `/kebab-case` 点名的 skill 必须存在（SSOT / 本地专用 / 插件 / 已知缺失四类之一）。与 S5 的分工：**S5 判会不会跑**（语义，只认显式声明），**S10 判这个名字还在不在**（字面，静态可判）。只认带连字符的斜杠写法——`/tmp`、`${…}/skills`、`A/B-test`、URL 路径段都不算引用；Claude Code 内置与上游家族里没引进的成员走脚本里的 `EXTERNAL_SLASH_REFS` 白名单（每条都注明理由） |

全局层（需本机 `~/.claude/`，CI 自动跳过）：断链 symlink 是红；
本机 skill 与 `SKILLS.md` 的收录差异是黄（队友机器天然不同，不该因此挡 PR）。
**G5**：声明了 `scope: project` 却仍出现在 `~/.claude/skills/` 是红——没有这条对账，
`scope: project` 就只是一句没人执行的注释。
**G6**：`~/.claude/settings.json` 的 `skillOverrides` 把被 `invokes` / `recommends` 指向的
skill 降到模型看不见（`off` / `user-invocable-only`）是黄，`--strict-global` 下升为红。
S6 只读 frontmatter 的 `disable-model-invocation`，读不到 settings——于是「skill 目录在、
`SKILLS.md` 也登记了，但本机已经把它关掉」这一类失效此前没人管，`feature-fullstack`
就是这么一路绿灯到人眼审计的。settings 是**个人文件**：CI 里不存在、队友机器也各不相同，
所以读不到就安静跳过、绝不报错。

S7 存在的原因是这仓库搬过一次家（`Desktop/AICAP` → `Desktop/AIProject/AICAP`），
写死的路径悄悄失效了很久没人发现。

# 测试约定（路径作用域规则）

> 这是一个**非 root、按 glob 作用域**的规则，演示"分层"——它只在 AI 接触测试文件时才进入上下文，
> 不污染日常会话。把领域专属约定都拆成这样的小文件，是规避"臃肿 SSOT"反模式的核心手段。

- 每个 bug fix 必须附一个能复现该 bug 的回归测试
- 测试命名描述行为而非实现：`it("rejects expired token")` 而非 `it("test1")`
- 不为覆盖率写空断言；断言要能在实现退化时真正失败
- 外部依赖在测试中 mock；不在单测里打真实网络 / 真实数据库
- 改了公共接口，先更新/新增测试，再改实现（test-first）
