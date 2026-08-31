---
name: learning-loop
description: |
  把一个话题学进长期记忆的个人学习闭环：研究摄入 → 闭书自解释 → 蒸馏成带真实引用的
  原子笔记 → 主动回忆测验 → 间隔重复排程。纯 markdown，无外部 app、无付费 API。
  新会话开始会自动扫笔记库，把今天到期的卡片推成复习队列。

  触发："学一下X / 帮我学X / 把X学进去" / "给X做笔记 / 做原子笔记 / make notes on X" /
  "考我 / 测我一下 / quiz me" / "今天有什么要复习 / what's due / 该复习什么了" /
  "间隔重复 / 抗遗忘 / spaced repetition / active recall / 闪卡 / flashcards /
  Anki 风格但不用 Anki" / "Zettelkasten / 卡片盒 / 费曼" / "Obsidian 笔记"。
  用户想把读到的东西真正记住、想建可复习的知识库时也应触发，不必逐字说出上述词。

  边界：不重做网络研究——宽泛或需多源核实的话题先用 survey 出带引用的报告，
  本 skill 只做「蒸馏 → 笔记 → 测验 → 排程 → 复习」这半程。
targets: ["*"]
invokes: ["deep-research", "survey"]
---

# learning-loop — 个人学习闭环

把一个话题**学进长期记忆**：`研究/摄入 → 理解 → 原子笔记 → 主动回忆测验 → 间隔重复排程 → 到期复习`。
全程**纯 markdown 文件 + 日期数学**,无 Anki、无服务器、无 UI、无付费 API——agent + 笔记文件 + 一次日期比较**就是整个系统**。

这个 skill 只做有证据的事:两条 HIGH 证据机制(**检索练习**=测验、**间隔效应**=排程)是骨架,中等证据的(费曼自解释、追问、交错、双编码)是廉价增强,流行但弱的(划线、重读、纯总结、学习风格神话)**主动避开**——分级见 `references/evidence.md`(锚 Dunlosky et al. 2013)。

## 它和你已有 skill 的边界(别抢活)
- **重研究 → 委派**:话题宽泛/不熟/需 >2 来源核实 → 先调 `deep-research`(出带引用报告)或 `survey`(出方案对比 `<topic>-完整报告.md`),**消费它们的报告**做蒸馏。本 skill **绝不**自己跑 fan-out 网搜或对抗式核实(那会重复更弱的逻辑、丢掉异构评审保障)。
- 只有「单个已知 URL / 小范围 fetch」才自己抓,且**先过 `references/sift.md`**(SIFT + 至少 1 次横向检索)。
- 本 skill 拥有的:`蒸馏 → 原子笔记 → 测验 → 排程 → 复习`。

## 核心铁律(必须扛过长对话的指令衰减——任何时候都不许破)
1. **每次会话先跑 Phase 0**:`date +%F` 取真实今天(或 `scripts/due.sh`),扫笔记库,把 `next_review <= 今天` 的卡推成复习队列,**先复习、再学新**。**绝不**用模型自己的时钟/训练截止猜日期。
2. **测验:先产出再揭晓**。只给线索(cue),**用户先凭记忆答出来**,才显示答案。绝不把答案和题并排、绝不在用户尝试前"帮忙"——否则把有效的"费力检索"降成无效的"被动阅读"(Roediger & Karpicke 2006)。
3. **每条事实笔记带真实引用**(作者/年份或 URL)。**禁止闭书编事实**:绑不到已抓取来源的事实要么丢弃、要么显式标 `unverified / 我的推断`。单一来源的承重结论标 `confidence: low`。
4. **排程是确定性规范、不是"判断"**:照 `references/scheduler.md` 的表**逐字执行并回显**算出的字段;`ease` 下限 1.3;日期增量用**序数日**相减(绝不用散文式心算日期);坏日期**大声报错**,绝不静默丢卡。
5. **委派重研究**给 deep-research/survey(铁律见上「边界」)。

## 工作流总览
| Phase | 文件 | 干什么 | 证据基础 |
|---|---|---|---|
| 0 | `phases/00-resume-due.md` | 会话开始,扫到期卡 → 复习队列(打散主题、最逾期/最 leech 优先) | 间隔效应 Cepeda 2006;交错 Rohrer 2020 |
| 1 | `phases/01-ingest.md` | 摄入/研究:**委派** deep-research/survey,或单 URL 走 SIFT 自抓 | SIFT Caulfield 2019;横向阅读 Wineburg 2019 |
| 2 | `phases/02-understand.md` | 理解门:闭书费曼自解释 + 追问补洞,**没理解不许写笔记** | 自解释 Bisra 2018;生成效应 Slamecka 1978 |
| 3 | `phases/03-distill.md` | 蒸馏成原子笔记:拆原子结论、逐条绑来源、忠实性核查、写 SR frontmatter | 原子笔记 Matuschak;FActScore Min 2023 |
| 4 | `phases/04-quiz.md` | 主动回忆测验(引擎):开放回忆题 → 预测-核对 → 自评 → 映射 4 档 | 检索练习 Roediger 2006;元认知 Koriat & Bjork 2005 |
| 5 | `phases/05-schedule.md` | SM-2-lite 排程:逐字套更新表、逾期补偿、leech 检测、写回 next_review | SM-2 Wozniak 1987;间隔 Cepeda 2006 |

正常学新:`1 → 2 → 3 → 4 → 5`。日常复习:`0 → 4 → 5`。

## Phase Read Gate(进每个 phase 前先 Read 对应文件——防长对话指令衰减)
进入某 phase **之前**,先 `Read` 它的 `phases/0X-*.md` 全文再执行。不要凭记忆做——这些文件是各 phase 的**唯一真相**。

## Template Read Gate(动手前先 Read 模板——防格式漂移)
| 动作 | 先 Read |
|---|---|
| 写**任何**笔记之前 | `assets/note-template.md`(原子笔记 + SR frontmatter 的逐字模板) |
| 出**任何**测验之前 | `assets/quiz-format.md`(题→预测→答→评分 的逐字交互格式) |
| 自抓单 URL 之前 | `references/sift.md` |
| 排程算分之前 | `references/scheduler.md`(SM-2-lite 固定表) |

## 笔记库位置(storage-agnostic,可配置)
- **默认库根** = `<cwd>/learning-vault/`(每项目一个;首次用会创建)。纯 `.md` + YAML frontmatter + `[[wikilinks]]`,Obsidian 原生渲染、**无需任何插件**,也兼容 Foam/Logseq/纯文件。
- 想用**全局库 / 你的 Obsidian 库**:设环境变量 `LEARNING_VAULT`(如 `export LEARNING_VAULT="$HOME/Desktop/Document/HK home/learning-loop"`),或在调用时直接说库路径。**不**硬编码 `~/.claude/...`(那是 claude-tutor 的反模式)。
- `scripts/due.sh [VAULT]` 会用 `$LEARNING_VAULT` 或第一个参数,默认 `./learning-vault`。

## 诚实关于证据(别把记忆增益归功于笔记好看)
留存提升来自**检索 + 间隔**,不是笔记美学。Zettelkasten/Cornell/evergreen 笔记是**手艺/中等证据**,实践框架(Forte/Ahrens/Matuschak)标注为**经验之谈、非 RCT**。绝不杜撰引用或效应量。完整分级:`references/evidence.md`。

## 借鉴来源(attribution)
- 阶段骨架借鉴 `sanyuan0704/sanyuan-skills@book-study`;测验深度借鉴 `FerroxLabs/wayland@active-recall-practice`;SM-2 借鉴 `kirilxd/claude-tutor`(并修正其硬编码 `~/.claude` 反模式);摄入委派给本机 `deep-research` / `survey`。
- 方法论锚:Dunlosky et al. (2013) PSPI 14(1):4-58。完整方法论→特性映射见本 skill 设计记录(2026-06-18 调研工作流)。
