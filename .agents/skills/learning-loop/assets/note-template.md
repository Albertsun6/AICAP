# note-template.md — 原子笔记逐字模板(写任何笔记前先 Read 这个)

> 复制下面整块,按注释替换。**纯 markdown + YAML**,Obsidian 原生渲染 `[[wikilinks]]`、**无需插件**,也兼容 Foam/Logseq/纯文件。SR 区块是清晰分隔的纯文本"岛",任何工具都不会破坏它。
> 文件名 = 一句**完整的断言式概念标题**(像 API 一样自描述),如 `间隔检索比集中重读更利于长期留存.md`。**一条笔记 = 一个想法**。

```markdown
---
id: 2026-06-18-spaced-retrieval-beats-massed-restudy   # 稳定 slug = 日期-概念
title: "间隔检索比集中重读更利于长期留存"                  # 断言式概念标题(= 文件名)
tags: [topic/memory, technique/retrieval-practice]
# --- SR 排程区块(纯文本,storage-agnostic;规则见 references/scheduler.md)---
ease: 2.5                 # float, SM-2 难度因子, 下限 1.3
interval_days: 0          # int, 上次排定间隔
reps: 0                   # 距上次 lapse 的连续成功数
lapses: 0                 # 累计失败(leech 计数; >=8 → leech)
last_review: null         # ISO-8601, 新卡为 null
next_review: 2026-06-18   # ISO-8601; 到期当且仅当 next_review <= 今天
state: new                # new | learning | review | relearning | leech
leech: false
# --- 接地/来源 ---
source: "Roediger & Karpicke 2006, Psychological Science 17(3):249-255"
confidence: high          # high | low (low = 单一来源 / 未核实推断)
sift: trusted             # 摄入判定: investigated | better-coverage-found | trusted
---

# 间隔检索比集中重读更利于长期留存

> 一个想法,断言式,用**学习者自己的话**。正文里**绝不**逐字抄原文。

## My Understanding   <!-- 费曼/自解释,闭书写(Phase 2) -->
背靠背重读同一材料感觉很有效,但留存增益很小;把同样的总时间**摊到几天**会逼你每次都
费力检索,而这正是巩固记忆痕迹的东西。

## Why / Elaboration   <!-- 追问式 elaborative interrogation: 为什么真? -->
为什么真?集中练习让你靠短期熟悉感"滑过去"(流畅性错觉);**间隔**重新引入了"已部分遗忘"
带来的合意困难(desirable difficulty)。

## Key Evidence
- Roediger & Karpicke (2006): 检索组一周遗忘 13%,重读组遗忘 56%。

## Cards   <!-- Phase 4 生成;答案在用户产出前**不可见** -->
- Q (recall): 集中重读 vs 间隔检索,长期留存如何不同?为什么?
  - must-have: 间隔 > 集中;机制 = 费力检索 / 合意困难
  - common-error: "一次多刷几遍 = 记得更牢"(把流畅当留存)
- Q (elaboration): 为什么集中重读"感觉"有效、其实不?

## Links   <!-- 强制 >=1 条;no-orphan 规则 -->
- [[合意困难让学习当下更难但记得更牢]]
- [[流畅性错觉让重读感觉像在学习]]

## Sources
- Roediger, H.L. & Karpicke, J.D. (2006). Test-Enhanced Learning. *Psychological Science* 17(3):249-255.
```

## 硬规则(写每条笔记都查)
1. **一条笔记一个想法**,标题是完整断言(不是话题名)。
2. 正文用**自己的话**(生成效应);不抄原文。
3. **强制 `## Links` 至少 1 条 `[[wikilink]]`** 到相关笔记(no-orphan;找到相关笔记本身就是自解释)。找不到就说明这是知识孤岛——补一条桥接笔记或质疑是否真理解。
4. **每条事实**在 `## Sources` / `source:` 有真实出处;单一来源承重结论 `confidence: low`。
5. 新卡的 SR 初值见上(ease 2.5 / interval 0 / reps 0 / lapses 0 / last_review null / next_review 今天 / state new)。
6. 例子、观点、你自己的推理**不需要**逐条接地(避免过度拆解);只有**事实**需要。
