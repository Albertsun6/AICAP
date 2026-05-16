---
name: debate-review
description: 收到外部 AI 对架构 plan / PR / 设计 / spec 的评审反馈后，用结构化辩论流程评估每条意见，形成接受 / 部分接受 / 反驳的判断矩阵，并把改动落到原文件。Use when user pastes a code review / architecture review / design critique from another AI and wants me to weigh each point with my own judgment instead of blindly accepting.
---
# debate-review skill — phase 3 裁决（Review Mechanism v2）

> **范围更新（v2，2026-05-03）**：本 SKILL 仅负责 **phase 3 裁决** —— 读 phase 1 verdicts + phase 2 react verdicts + author counter，4 档分类 + 应用修复。
>
> **phase 2 cross-pollinate** 由 [`PHASE_2_PROMPT.md`](PHASE_2_PROMPT.md) 模板 + 各项目自带的 phase 驱动脚本触发，**不在本 SKILL 范围**（v1 期 SKILL 把 phase 2 + 3 合在一起，v2 期拆开）。
>
> **关联**：完整三层评审机制（phase 1 双盲 → phase 2 cross-pollinate → phase 3 裁决）由各项目自身的评审机制文档定义；本 SKILL 只实现 phase 3 裁决这一层。

## 输入合约（fail-loud，dogfood Round arch react N1 修复）

phase 3 启动前必须有以下 4 份文件全部存在（M1+ 跳过 phase 2 时按 §3 跳过日志走，但 phase 1 verdict 仍需）：

```
docs/reviews/<artifact>-arch-<TS>.md            # phase 1 arch verdict
docs/reviews/<artifact>-cross-<TS>.md           # phase 1 cross verdict
docs/reviews/<artifact>-arch-react-<TS>.md      # phase 2 arch react (or skipped log)
docs/reviews/<artifact>-cross-react-<TS>.md     # phase 2 cross react (or skipped log)
```

**缺任一文件 → SKILL 拒绝裁决**，要求作者先补齐或显式标记 phase 2 skipped（跳过日志格式按各项目的评审日志元配置约定）。这避免 author 静默跳过 phase 2 而 phase 3 仍被当作"完整三层"。

**M1+ skip phase 2 合法路径**（OQ1 触发条件不满足）：在 REVIEW_LOG round 段填 `phase 2: skipped` + 完整 trigger check + source-of-truth；本 SKILL 接受但记录 phase 2 = none 状态。

## 触发场景

用户粘贴外部评审反馈并明示或暗示要"有主见地处理"，或者用户已经跑完 phase 1 + phase 2 后要 author 综合判断。常见提示词：
- "以下是评审结果"
- "另一个 AI 评审"
- "你要有主见，评估他的结果"
- "经过多轮辩论"
- "评审反馈如下"
- "phase 2 verdict 已到，跑 phase 3"

## 五步流程

### 1. 通读 + 抽提主张

把评审分解为独立"主张单元"——每个单元一句话能复述。区分：
- **必须先改类**（评审者标 must / blocker / 严重 / 不可接受）
- **方向类**（评审者整体判断、推荐节奏、整体取舍）
- **细节类**（具体设计点、字段命名、API 形状等）
- **未回答类**（评审跳过的原 Open Question）

### 2. 逐条判断（四档）

每个主张分到下面四档之一：

| 档 | 触发条件 | 处理 |
|---|---|---|
| ✅ 接受 | 主张属实 + 改动可控 + 无更优替代 | 落 plan，无须辩论 |
| ⚠️ 部分接受 | 方向对但分寸过 / 不及；或评审给的方案过简 / 过繁 | 写反提案，融合双方视角 |
| 🚫 反驳 | 评审有事实/理解错误，或有更强反论据 | 写论据 + 引文，不落 plan，等下一轮挑战 |
| 🟡 挂起 | 缺数据，需 dogfood 验证 | 标 Open Question 留下一轮 |

判断时刻意带**对抗思维**：评审是另一个 AI 给的，可能有自己的盲点和保守倾向。不要因为"对方写得有理有据"就全盘接受——要看它的论据在我所知的项目上下文里是否真站得住。

### 3. 反向挑战评审者

评审 AI 也会有盲点。每次都要查：
- 哪些原 Open Questions 评审跳过了？跳过 ≠ 同意。
- 评审是否误读了某段？（看是否引用 plan 段号正确）
- 评审有没有"集体盲区"——如果它和被评者用同代模型，会不会一致漏看？
- 评审给的建议是否过抽象（如"窄腰架构"），缺具体取舍？应要求其下一轮给出具体收缩点。
- 评审是否回避了最尖锐的问题？

挑战写进辩论矩阵，下一轮交评审时呈给评审者。

### 4. 写辩论矩阵到原文件

在原 plan / 设计文档里加一节"评审辩论流水"，用表格记录：

| 评审主张 | 我的判断 | 处理 |
|---|---|---|
| ... | ✅/⚠️/🚫/🟡 | 段号 / 反提案要点 |

下次评审时同节追加新一轮（vN → vN+1 的判断）。这个矩阵就是**长期记忆**——同一个 plan 可经多轮评审而不丢失早期决策依据。

### 5. 落改动 + 收尾

- 接受类的改动直接 Edit 落地到原文件
- 部分接受类写反提案进 plan
- 反驳类不改 plan，但在矩阵里写论据
- 收尾用文本简短报告：接受 N / 部分接受 N / 反驳 N / 挂起 N + 关键反提案 1-2 条 + 反向挑战 1-2 条

## 自我完善机制

每次跑完 debate-review，往 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/debate-review/log.jsonl` 追加一条 JSON 记录：

```json
{"date": "2026-05-01", "planFile": "...", "totalClaims": 17, "accepted": 13, "partial": 2, "rejected": 0, "hung": 0, "biggestInsight": "evaluator 被污染（reviewer 不应读 coder transcript）", "biggestMistake": "§0 与 §6.1 自我矛盾：写了不做日历估算却保留了'第 1 周'残留", "newPrinciplesAdded": 3, "newRisksAdded": 6}
```

字段定义：
- `date`：辩论发生日
- `planFile`：被评审的文件绝对路径
- `totalClaims / accepted / partial / rejected / hung`：四档计数
- `biggestInsight`：评审给我的最有价值洞察（为下次记忆）
- `biggestMistake`：我自己被指出的最大问题（为下次警惕）
- `newPrinciplesAdded / newRisksAdded`：本轮在 plan 里新增了几条原则 / 风险

**累积条件触发自我完善**：
- log.jsonl ≥ 5 条：扫一遍找高频 insight / mistake，沉淀进本 SKILL.md "常见模式" 段
- log.jsonl ≥ 10 条：把高频反驳论据形成"评审者常见盲点"清单加到 §3
- 每次 skill 触发先读 log 末尾 3 条，避免重复犯错

## 反例（不要这样做）

- ❌ **全盘接受评审**：失去主见，plan 反复被同一意见来回拉扯；评审 AI 不一定比作者更懂项目上下文。
- ❌ **全盘反驳**：自负，浪费评审价值；如果收到合理批评仍硬扛，下次评审会失去信任。
- ❌ **不写辩论矩阵直接改 plan**：丢失辩论历史，下次评审看不到上次为什么这么改，容易循环讨论同一个点。
- ❌ **把"评审跳过的问题"当成"评审认可"**：跳过 ≠ 同意，要主动追问到底。
- ❌ **被评审 AI 的语气威慑**：评审者用强烈措辞（"必须""错误""严重"）不等于它对——同样要看论据。
- ❌ **遗漏挑战评审者的环节**：单方面接受改动而不反向问问题，相当于免费给评审者打工。

## 常见模式（随 log 累积自动沉淀）

_本节由 log.jsonl ≥ 5 条触发后自动维护。当前为初始版本，无沉淀模式。_

## 评审者常见盲点（随 log ≥ 10 条触发）

_当前为初始版本，无盲点清单。_
