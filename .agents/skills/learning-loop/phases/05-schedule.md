# Phase 5 — 排程(SM-2-lite,确定性日期数学)

> 把测验评分套成**固定确定性规范**(绝不用模型"判断"),算出新的 `next_review`(序数日算术),把更新后的 frontmatter **写回**笔记,并处理逾期/leech。
> **算分前先 Read `references/scheduler.md`** —— 那是唯一真相,这里只是流程外壳。
> 证据:间隔 Cepeda 2006;算法 SM-2(Wozniak 1987)/ Anki 4 档;逾期 controlaltbackspace;leech Anki Manual;FSRS 故意不手算(Ye/Su/Cao 2022)。

## 步骤
1. **取评分**:从 Phase 4 拿到这张卡的 `again/hard/good/easy`。
2. **套更新表**(逐字,见 scheduler.md):按评分更新 `ease / interval_days / reps / lapses / state`;每步 clamp `ease >= 1.3`。
3. **逾期补偿**:`delay = max(0, 今天 - next_review)`;非 again 评分按 Easy 全/Good 半/Hard 0 把 delay 加进 interval 再乘;下一个间隔基于实际经过回忆跨度,`max_interval` 封顶 365;很陈旧 + again 直接重置 relearning。
4. **算 next_review**:`next_review = 今天 + interval_days`(ISO-8601);`last_review = 今天`。**用序数日相减**(`scripts/due.sh` 的封装,或 scheduler.md 的 `date -j/-d` 配方),**绝不**散文心算。
5. **leech 检测**:`lapses >= 8`(可配,严格 4)→ `state=leech, leech=true`,停止排程,提示用户**重写/拆分**这条笔记(回到原子笔记纪律);重写后重置 `lapses=0, ease=2.5, state=new`。
6. **写回 + 回显**:把新 frontmatter 写回笔记文件,并**回显**算出的字段让用户能核对(`ease 2.5→2.5, interval 6→15, next_review=2026-07-03`)。

## 不许
- 不许用"感觉这张该过几天"代替公式。
- 不许散文心算日期(off-by-one/月长/闰年极易错)。
- 不许坏日期静默丢卡——大声报错让用户修。
