# skill-creator 方法论异构评审 · 2026-07-29

**评审对象**：Anthropic 官方 `skill-creator` 的 description 评测/优化方法，
以及本仓库自建的 `promptfoo/run-trigger-eval.py`。

**为什么评审**：准备用 skill-creator 优化本仓库 24 个 skill 的 description 之前，
先确认它的方法本身站不站得住。单模型自评 = 共享盲区。

**方法**：两个异构族各跑一次独立评审，发现取并集、不投票。

| 族 | 模型 | 产出 |
|---|---|---|
| GPT | `gpt-5.6-sol-xhigh` | 555 行 |
| Gemini | `gemini-3.1-pro` | 56 行 |

---

## 一、两只眼独立一致的结论（高置信）

| # | 结论 | GPT | Gemini |
|---|---|---|---|
| 1 | 「首个非 Skill/Read 工具即 `return False`」是致命假阴性 | ✅ 列举 6 类正常流程被误杀 | ✅「直接惩罚 Agent 优秀的思维链」 |
| 2 | 「按 test 选最优」不防过拟合，只是把 test 变成 validation | ✅ 需 train/validation/final 三层 | ✅「教科书级过拟合制造机」 |
| 3 | 8 条 test × 3 次采样统计上不足 | ✅ 观察 2/3 时真实概率 95% 区间约 9%–99% | ✅ 一条翻转即波动 12.5% |
| 4 | description 会被越优化越长（打补丁式防御条款） | ✅ 评分函数完全不惩罚新增排除条件 | ✅ 变成「防御性面条」 |
| 5 | **最该改的一件事：单 skill 孤岛 → 全 skill 竞争** | ✅ | ✅ |

第 5 条两只眼几乎给出同一句话。Gemini 的表述最精炼：

> 方法 A 评估的是**存活率**，方法 B 评估的是**生态位**。

孤岛评分会奖励「贪婪型描述」——让自己更容易被触发，代价是抢走邻居的活，
而孤岛测不到这个代价。

## 二、GPT 独有、且已被我实测确认的实现缺陷

| # | 缺陷 | 我的验证 |
|---|---|---|
| 1.4 | 并发 worker 互相污染 | 实锤：`ProcessPoolExecutor(max_workers=10)` 共用同一个 `project_root`，各自在 `.claude/commands/` 建同内容、不同随机后缀的临时命令 → 任一时刻可有 10 个同义候选互相分流，且三次运行的实验条件不一致（非独立同分布） |
| 1.10 | 基础设施错误被当成「未触发」 | 实锤：`except Exception → append(False)`，且 `stderr=DEVNULL`。**不对称污染**——对正例造成红，对负例造成**假绿** |
| 1.5 | 它同时改了 name 这个变量 | 属实：`report-to-html` → `report-to-html-skill-<hex>`。name 本身是路由信号，却把结果全归因于 description |

## 三、我自己实测发现的（评审之外）

| 发现 | 证据 |
|---|---|
| 需要 Python 3.10+ | 系统自带 3.9 直接 `TypeError`（PEP 604 `str \| None`） |
| 假阴性真实存在 | 一条正例被判 `triggers: 0`，手工跑同一句话，**第一个工具就是 `Skill`** |
| 空 `CLAUDE_CONFIG_DIR` 不能用来隔离 | 订阅凭据也存在该目录，实测直接 `Not logged in` |

## 四、判断矩阵：我不全盘接受的部分

| # | 评审意见 | 我的裁决 | 理由 |
|---|---|---|---|
| A | Gemini：「负例必须是近邻」这条**有害**，会导致过度特化/灾难性遗忘，应 30% 近邻 + 70% 常规 | **部分接受** | 两者语境不同、不矛盾：skill-creator 讲的是「生成用例时别只用明显负例」（否则测不出东西），评审讲的是「优化时别只用近邻负例」（否则过度特化）。正解是**混合**。 |
| B | GPT：「简单请求不应放进测试」是危险的循环定义 | **接受** | 不能因为当前路由器不爱触发短请求，就把短请求删掉再宣布召回率好。 |
| C | GPT：「真实 query 必须有很多路径/公司名/背景故事」不成立 | **接受** | 真实用户也会打「把这个报告做成网页」。真实度应来自生产分布，不是句子长度。 |
| D | GPT：description 不是唯一触发因素（还有 name / 候选集 / 系统提示 / 工具 / 历史 / 模型版本） | **接受** | 这也解释了为什么孤岛测试的结论迁移不到生产。 |

### 我被驳倒并已更正的

- 我先前对用户说「我们的负例太容易，是缺陷」——**说过头了**。那两条简单负例
  （"写个字符串反转函数" / "今天北京天气"）按 B、C 两条应当**保留**；
  真正缺的是**补**近邻负例，而不是把简单负例换掉。

## 五、落地

采纳「只借它的测量层，不用它的孤岛优化」（两只眼一致指向的方案），
新建 `promptfoo/run-arena-eval.py`，逐条避开上述缺陷：

| 官方实现 | 本仓库 arena runner |
|---|---|
| 首个非 Skill/Read 工具即终止 | 解析**完整轨迹**，收集全部 Skill 调用 |
| 异常/超时 `append(False)` | 单列 **ERROR** 状态，不参与 pass/fail |
| 一次只注入一个 skill | **全 SSOT skill 同场竞争** |
| 改 name 为 `<name>-skill-<hex>` | 用**真实 skill、真实名字** |
| 期望值是布尔 should_trigger | 期望值是**集合**（0 / 1 / 多个） |

候选集受控方式：`~/.claude/skills` 的 personal 层覆盖 project 层，所以 SSOT skill
本来就在场；在临时项目用 `skillOverrides` 关掉 9 个非 SSOT 本地 skill，
再 `disableBundledSkills` 关掉内置的。（不能用空 `CLAUDE_CONFIG_DIR`——见三。）

**两套 eval 是互补关系，都要保留**：

- `run-trigger-eval.py` —— 元认知问询，便宜快（~5s/条），防回归
- `run-arena-eval.py` —— 行为测量，贵（数十秒/条），测真实路由

模型「说」它会触发什么 ≠ 它**实际**触发什么。

---

## 六、落地后的实际发现（跑了四轮才拿到干净数据）

前三轮的红**全部是 runner 自己的问题**，没有一条是描述问题。这本身是这次最该记住的事：
**先怀疑测量工具，再怀疑被测对象。**

| 轮 | 症状 | 真实原因 | 修法 |
|---|---|---|---|
| 1 | 10 条里 4 条 `timeout` | 重型 skill（`survey` / `project-health`）被触发后**真的开始跑多阶段流程**，等它结束必然超时——而那个超时跟触发准确度毫无关系 | 首次命中后只再观察 12 秒（`SETTLE_SECS`）就收工 |
| 2 | `project-health` / `project-context` 混入 `aicap-commit` | 把「`Read` 了某个 SKILL.md」当成触发。临时 arena 近乎空目录，唯一实质文件就是补进去的项目级 skill 的 `SKILL.md`，「看看这个仓库」一探索就读到它 | **只认 `Skill` 工具调用**。读文件 ≠ 路由到 skill |
| 2 | 2 条 `timeout` | 骨架太空，用例说的「这个仓库」「auth 模块」都不存在，模型一直翻 | 补最小项目骨架 |
| 3 | `diagramming-code` 不触发 | 骨架里 auth 只有一个 4 行函数。模型原话：*"a single file with a single function, so the call graph is small and I can [do it myself]"* | 骨架加到 9 文件 87 行、auth 三个文件有交叉调用 |
| 4 | `diagramming-code` **仍**不触发 | ← 这条才是真的 | 见下 |

第 2 行那个假阳性，**两只异构眼都明确预警过**（GPT 1.8：「把直接 Read 临时文件也算作触发……
混合了两个不同事件：查看 skill 文件 / 选择并执行 skill」）。读了警告仍然踩进去——
说明静态评审读懂了不等于实现时避得开，必须真跑。

### 唯一确凿的描述缺陷：`diagramming-code`

原 description 第一句是 `Generates Mermaid diagrams from Trailmark code graphs.`——
把 **Trailmark 这个实现依赖放在最显眼位置**，模型读成前置门槛，判定「项目里没有 Trailmark
所以用不了」，转而自己 Glob + Read 六个文件手工画图。

官方文档那句 *Put the key use case first* 讲的正是这件事，而这个描述恰好反着来。

**受控 A/B**（两个同构名字 `diagramming-code-v1` / `-v2`，唯一变量是 description，
全局同名真身用 `skillOverrides` 关掉避免干扰）：

| 版本 | 首句 | 触发 |
|---|---|---|
| v1（原） | 工具依赖打头 | **0 / 2** |
| v2（新） | 用途打头，Trailmark 后置为「为什么可信」 | **2 / 2** |

已按此改 SSOT。这是竞技场 eval 第一次抓到真实的描述缺陷——
而它恰恰是**孤岛式优化抓不到、也想不到要抓**的那一类：单看 `diagramming-code`
的触发率低，你只会往 description 里**加**触发词；真正的病因是首句站错了位置。
