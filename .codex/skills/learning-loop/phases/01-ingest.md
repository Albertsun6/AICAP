# Phase 1 — 摄入 / 研究(委派为主)

> 目标:为新话题拿到**可信、带引用**的源材料。本 skill **不**重做网络研究——把重活路由给你已有的 `deep-research` / `survey`,消费它们的带引用报告。证据:编排者-工作者上下文隔离(Anthropic eng 2025-06-13);来源核查 SIFT(Caulfield 2019)+ 横向阅读(Wineburg & McGrew 2019)。

## 路由规则(会话开始就判)
- **(a) 话题宽泛 / 不熟 / 决策型 / 要多源核实的报告** → 调用 `deep-research` skill,把它的**带引用报告**作为摄入输入。
- **(b) "别人怎么做 X" / 方案对比** → 调用 `survey` skill,消费它的 `<topic>-完整报告.md`(已自带引用健康度 + Source Inventory)。
- **(c) 仅单个已知 URL / 小范围 fetch** → 本 skill 自己轻量 `WebFetch`,但**先过 `references/sift.md`**(SIFT + 至少 1 次横向检索再决定信不信)。

## 硬边界(写进 SKILL.md 铁律,这里重申)
> **任何需要 >2 来源、或你本来就不信任的材料 → 停,先调 deep-research/survey,从它们的报告续做蒸馏。**
不要在本 skill 里做浅层网搜——那会重复更弱的逻辑、丢掉异构评审保障。

## 带走引用
把每个来源的引用(作者/年份或 URL)**一路带下去**——它会传播进每条笔记的 `source:` / `## Sources`。三角验证沿用 survey 的"≥2 独立来源"规则(Denzin 1978);可复用 `survey/references/source-quality.md` 的来源质量打分,别另造。

## 产出
一份(或几段)**带引用的可信材料**,交给 Phase 2 理解门。不要在这里就开始写笔记。
