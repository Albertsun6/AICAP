# scheduler.md — SM-2-lite 间隔重复规范(确定性,逐字执行)

> 这是 Phase 5 的**唯一真相**。把它当成**固定查表**,逐字套、并**回显**算出的字段(`ease / interval_days / reps / lapses / next_review / state`)。**绝不**用模型"判断"代替公式。

## 为什么是 SM-2-lite(而不是别的)
- **选它**:忠实于被引用最多的间隔算法(SM-2),又能化简成 LLM 可靠执行的整数/浮点算术。
- **不用原始 6 档 SM-2**:0–5 质量打分难从聊天 LLM 稳定问出。改用 Anki 风格 **4 档**(again/hard/good/easy)。
- **拒绝 FSRS 手算**:17–21 个权重要在用户自己的复习日志上**训练**、非线性、手不可验、冷启动无意义(Ye/Su/Cao 2022, KDD'22)。**升级路径**:攒够几个月 frontmatter 日志后,用官方 FSRS optimizer 拟合——不要假装手算 FSRS。
- **Leitner lite-mode**:仅作逃生舱(见文末)。

## frontmatter 状态字段
| 字段 | 类型 | 初值(新卡) | 含义 |
|---|---|---|---|
| `ease` | float | `2.5` | SM-2 难度因子,**下限 1.3** |
| `interval_days` | int | `0` | 上次排定的间隔(天) |
| `reps` | int | `0` | 距上次 lapse 的连续成功次数 |
| `lapses` | int | `0` | 累计失败数(leech 计数;`>=8` → leech) |
| `last_review` | ISO-8601 或 null | `null` | 上次复习日 |
| `next_review` | ISO-8601 | `今天` | **到期当且仅当 `next_review <= 今天`** |
| `state` | enum | `new` | `new\|learning\|review\|relearning\|leech` |
| `leech` | bool | `false` | 是否已标记 leech |

全程用 **float**(2.5 / 0.20 / 0.15 / 1.3),**绝不**把百分数(250/130)和 float 混用。

## 更新规则(逐字套用,然后回显)
设当前 `interval` = `interval_days`,`ease` = 当前 ease。

- **NEW(新卡)**:`ease=2.5, interval_days=0, reps=0, lapses=0, state=new, next_review=今天`。
- **AGAIN(答错/lapse)**:`lapses += 1; reps = 0; ease = max(1.3, ease - 0.20); interval_days = 0; state = relearning`。
- **HARD**:`ease = max(1.3, ease - 0.15); interval_days = round(max(interval*1.2, interval+1))`。
- **GOOD**:`if reps==0 → interval_days = 1; elif reps==1 → interval_days = 6; else → interval_days = round(interval*ease)`;`ease` 不变;`reps += 1; state = review`。
- **EASY**:`ease = ease + 0.15; interval_days = (4 if reps==0 else round(interval*ease*1.3)); reps += 1; state = review`。
- **每一步都 clamp `ease = max(1.3, ease)`**(下限 1.3 防止间隔坍缩成无限复习)。
- **`next_review = 今天 + interval_days`**(写成 ISO-8601);`last_review = 今天`。

> 这套是 Anki 风格 SM-2 变体(super-memory.com/english/ol/sm2.htm, Wozniak 1987;Anki FAQ),与原始 SM-2 的唯一刻意分歧:**lapse 时把 ease 调低**(原始 SM-2 不在此处降 ease)——这是 Anki 的成熟做法,记录在案。

## 逾期稳健(应对"几周没复习")
1. `delay = max(0, 今天 - next_review)`(序数日相减)。
2. 非 AGAIN 评分:在乘之前给 interval **加一部分 delay** —— EASY 加**全部** delay、GOOD 加 **delay/2**、HARD 加 **0**。
3. 下一个间隔基于**实际经过的回忆跨度**(`今天 - last_review`)而非原定 interval,这样隔很久还能答对要奖励、但**封顶**。
4. **`max_interval = 365`** 天封顶。
5. **很陈旧 + AGAIN** → 直接重置为 relearning,**别信**旧 interval(SM-2 对严重逾期卡过于激进——Control-Alt-Backspace)。

## leech(顽固卡)处理
- `lapses >= 8`(可配,严格模式可设 4)→ `state=leech, leech=true`,**停止**进入正常复习,提示用户**重写/拆分**这条笔记(leech 通常意味着原子笔记太大或没真懂——回到原子笔记纪律)。
- 重写后重置:`lapses=0, ease=2.5, state=new`。

## 日期数学(off-by-one 是大忌)
- **今天**必须来自真实 `date +%F`(或 `scripts/due.sh`),**绝不**用模型时钟。
- 所有日期 ISO-8601(可字典序排序)。
- 整天差 = 两个 ISO 日期各转**序数日**再相减:
  - macOS/BSD:`date -j -f "%Y-%m-%d" "2026-06-18" "+%s"`,除以 86400。
  - GNU/Linux:`date -d "2026-06-18" "+%s"`,除以 86400。
  - `scripts/due.sh` 已封装并自动探测 GNU/BSD。
- **绝不**用散文式心算日期(月长/闰年/进位极易错)。
- 坏/缺日期 → **大声报错**(让用户修),绝不把卡静默踢出复习。

## Leitner lite-mode(逃生舱,config flag)
不想要 ease 记账时:`state = box1..box5`,固定间隔 `[1, 3, 7, 16, 35]` 天;答对 `box+1`,答错回 `box1`。无 ease 簿记。
(注:这些天数是现代约定,**非** Leitner 1972 原版——原版只规定 5 格、间隔递增。)

## 算过但没用的算法(留痕)
- **FSRS**:已评估,**故意不手算**(理由见顶部);升级路径=导出 frontmatter 日志用官方 optimizer 拟合。
- **原始 6 档 SM-2**:质量分难稳定问出,改 4 档。
