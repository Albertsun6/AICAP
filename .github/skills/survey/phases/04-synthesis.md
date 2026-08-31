# Phase 3-5：综合 + 对比矩阵 + 报告 + Audio Summary

## Phase 3：结构化对比矩阵

基于 Phase 2 的发现，构建对比表格：

```markdown
| 方案 | 维度1 | 维度2 | 维度3 | 维度4 | 综合得分 |
|------|-------|-------|-------|-------|----------|
| A    | 4 ✓   | 3     | 5 ✓   | 2     | 3.5      |
| B    | 3     | 5 ✓   | 3     | 4 ✓   | 3.75     |
| C    | 2     | 4     | 4     | 5 ✓   | 3.75     |
```

规则：
- ✓ = 该维度最优（可并列）
- ? = 数据不足，不填空分
- 评分 1-5，说明打分依据（一句话）
- 每格标注关键来源

Phase 2 结束后启动综合 Agent，读取 A+B+X1+X2（默认）或降级后的组合（见 `02-research.md` §自动降级矩阵）的独立发现，**按并集**构建合并矩阵（不投票、不因单方独有而丢弃，规则见 `02-research.md` §合并规则），并标注各方分歧点与 X1/X2 独有 source。

---

## Phase 4：冲突分析（ACH-lite）

标出来源之间的重要分歧，逐一处理：

1. **找出分歧**：哪些结论在来源之间相互矛盾？
2. **寻找反证**：对当前看起来最优的方案，主动搜索 "X problems" / "X failed"
3. **置信度评级**：
   - **高**：≥3 个独立权威来源一致
   - **中**：2 个来源，或 1 个权威来源但有异议
   - **低**：单一来源，或存在明显反证

---

## Phase 5：建议输出

按以下模板输出最终结果：

```markdown
## 研究问题
[标准化的问题陈述]

## 评估维度
[列出 Phase 1 确定的维度及权重]

## 方案对比

| 方案 | 维度1 | 维度2 | 维度3 | 综合 |
|------|-------|-------|-------|------|
| ...  |       |       |       |      |

> ✓ 该维度最优　? 数据不足

## 主要来源
- [来源名称](url) — 置信度：高/中/低，支持方案X
- （每个关键结论至少 2 条来源）

## 推荐

**结论**：[一句话]

**理由**：[为什么这个方案赢了，接受了哪些权衡]

**适用条件**：[在什么场景下这个建议最有效；什么情况下需要重新评估]

**置信度**：[高/中高/中/低]（基于 N 个来源）

## 待验证风险
- [ ] [具体不确定点 + 如何验证]
- [ ] ...

## 调研 Metadata

- **澄清 (Phase 1.2)**: <未触发——无 blocking unknown / 触发 N 轮共 M 问（一句摘要） / 未执行（<原因>），基于假设: <列表>>——降级/3 轮到限时此行是用户看到"靶子怎么立的"的唯一渠道，不许省
- **前提破裂 (Phase 2.5)**: <未触发 / <证据> + 用户裁决: <按原题继续 / 换靶> / <证据>, 未经用户裁决（非交互）>（未触发时此行可整行省略）
- **异构模型**: X1=<实际 model id> / X2=<实际 model id> / R1主评审=<实际 model id> / R1红队=<实际 model id>（各自降级时写 `无（已降级：<原因>）`）
- **X2 增量**: <X2 独有且最终核实通过的发现数 N / X2 独有但被 Drop 的数 M>——这是判断"第二只眼值不值配额"的数据，持续为 0 应考虑撤掉 X2
- **红队增量**: <红队独有条目数 N / 其中最终 accept 或 partial 的 M / 两方共提的 K>——同理，这是判断"红队值不值配额"的数据；连续几次 N=0 或 M=0 就该考虑撤掉红队（`red-team: unavailable` 时写 `无（红队未跑：<原因>）`）
- **Phase 6 异构终审 verdict**: 主评审=<Concur / Refine / Dissent> / 红队=<Concur / Refine / Dissent / unavailable (<原因>)>
- **辩论收敛**: <Concur 直通 / 自动收敛 Round N / 人类裁决终止 Round 3+>
- **事实 tiebreaker**: <裁决 N 条 / 未触发 / unavailable (<原因>)>
- **人类介入**: <无 / 用户裁决 K 条>
- **Output**: <cwd 报告路径 或 `write failed (<reason>); inline only`>
- **Filename collision**: <none / detected, saved as <final-path>>
- **HTML**: <path 或 `failed (<reason>)` / `skipped (<reason>)`>
- **PDF**: <path 或 `failed (<reason>)` / `skipped (<reason>)`>
- **Audio(概要)**: <path 或 `skipped (<reason>)` / `failed (<reason>)`>
- **Audio(完整)**: <path 或 `skipped (<reason>)` / `failed (<reason>)`>

#### Phase 6 辩论历史（仅 Refine / Dissent 时；只放 metadata，不进正文推荐区）

##### Round 1：主 agent 判断矩阵（主评审 + 红队条目并集）
| 来源 | 建议 | 立场 | 论据 / 证据 |
|---|---|---|---|
| `[R1-主评审]` \| `[R1-红队]` \| `[两方共提]` | <reviewer 建议简述> | accept \| partial \| defer \| refute（refute 必附 `reason: unsupported \| contradicted`） | 一句话；contradicted 必附 URL |

##### Round 2（如有未 accept 的建议）：cursor-agent rebuttal + 主 agent 二轮判断
| 建议 | cursor-agent 反驳要点 | 主 agent 立场（维持 / 让步） | 论据 |
|---|---|---|---|

##### Round 3（如 Round 2 后仍有分歧）：cursor-agent 二次 rebuttal + 主 agent 三轮判断
| 建议 | cursor-agent 二次反驳 | 主 agent 立场 | 论据 |
|---|---|---|---|

##### 事实核查 tiebreaker（仅有事实性分歧时；默认 gemini 族实查，回避/不可用时 grok，须写明实际族）
| # | 争议点 | verdict | 依据 URL | 理由 |
|---|---|---|---|---|
| 1 | ... | REVIEWER_对 \| MAIN_对 \| 都不对 \| UNRESOLVED（转人类）\| OUT_OF_SCOPE（转人类） | https://... | ... |

##### 人类裁决（仅 tiebreaker 后仍有未收敛分歧时）
| 建议 | 主 agent 最终立场 | cursor-agent 最终立场 | 用户裁决 | 用户备注 |
|---|---|---|---|---|
```

---

## Finalize 输出步骤（Phase 6 收敛后、Audio 之前强制执行）

> 原则：最终报告 + HTML + audio 默认落到 cwd（用户启动 Claude Code 时所在目录），不再只在对话里 markdown 输出。中间产物（prompt / subagent 输出 / citation JSON）继续留 /tmp。

### 产物分档（先定档，再按档执行下方步骤）

见 SKILL.md §输出分档。**A 档（内部输入）只做步骤 1-4 + 步骤 6 的 metadata 收尾，跳过 4.5/4.6/5**：
- `HTML` / `PDF` / `Audio(概要)` / `Audio(完整)` 四个字段一律写 `skipped (档位 A：内部输入)`
- 报告正文按 A 档写法收敛（≤80 行：结论/改哪里/证据账本/待验证）
- **B 档**执行 4.5/4.6（HTML+PDF），跳过步骤 5（audio）→ audio 字段写 `skipped (档位 B)`
- **C 档**全做

分档不影响 Phase 1-6 的任何质量门禁——**门禁不分档，产物才分档**。

### 触发时机（**唯一触发点**）

- Phase 6 §收敛检查全部通过，**合法收敛路径共 5 条**：**Round 1 Concur** / **Round 2/3 双方同档（无分歧）** / **tiebreaker 裁清全部剩余分歧** / **人类裁决完成** / **Phase 6 整段被跳过（Round 1 失败或双眼皆挂）——此时必须已按 06-debate.md §降级 打 SKIPPED banner 再 finalize**
- Phase 6 §收敛之前**禁止**写 cwd 文件——包括 Round 1 verdict=Refine 时的判断矩阵、Round 2/3 rebuttal 中的中间 markdown
- 顺序：Phase 5 模板 → Phase 6 多轮辩论 → 收敛 → 合成最终 markdown → Finalize 输出步骤
- Phase 6 metadata 与正文一次性合成（避免分两次写报告主体）；audio 状态字段例外，见步骤 5-6 二次写法

### 步骤

1. **从研究问题提取主题**（主 agent 自动）
   - 中文：8-15 字；英文：3-6 单词（kebab-case）。用户研究问题是中文则中文主题，是英文则英文主题
   - 去掉助词与"的"，保留关键词
   - 例（中文）：`3-5 人小团队借助 AI 做大型软件 → 3-5人AI团队做大型软件`
   - 例（英文）：`Comparison of Python async frameworks → python-async-frameworks-comparison`
   - **强制 slug 化**：替换路径敏感字符 → `_`：`/` `\` `:` `*` `?` `"` `<` `>` `|` 换行制表符
   - 保留：中文、英文字母、数字、`-` `_` `.`
2. **拼装 cwd 路径**：从 Bash `pwd` 取 cwd，拼出五个目标路径：
   - `<cwd>/<topic>-完整报告.md`
   - `<cwd>/<topic>-完整报告.html`
   - `<cwd>/<topic>-完整报告.pdf`
   - `<cwd>/<topic>-音频概要.m4a`
   - `<cwd>/<topic>-完整音频.m4a`
3. **同名冲突处理**：用 Bash 检测 `.md` 目标文件是否存在（`.html` / `.pdf` / 两个 `.m4a` 沿用相同 topic + 后缀，自动跟随 `.md` 的最终编号）
   - 不存在 → 直接写；§metadata 写 `Filename collision: none`
   - 存在 → 尝试 `-2`、`-3`、`-4` 累加后缀直到不冲突；§metadata 写 `Filename collision: detected, saved as <final-path>`
   - **不覆盖、不询问**——保留旧调研产物
4. **写报告 v1**：用 Write 工具落综合 markdown 到目标路径，§metadata 中：
   - `Output: <最终路径>`
   - `澄清 (Phase 1.2): <未触发 / 触发 N 轮共 M 问 / 未执行（<原因>），基于假设: <列表>>`——照 Brief「用户澄清记录」字段抄状态，别凭记忆；有前提破裂事件再加 `前提破裂 (Phase 2.5): <证据 + 用户裁决结果 / 未经用户裁决>`
   - `异构模型: X1=<id> / X2=<id> / R1主评审=<id> / R1红队=<id>`——**逐个抄脚本输出的 `MODEL: <id> (family=<族>)` 实际值**（Phase 6 的两路要等 Round 1 跑完回填），模型是运行时按族解析的（见 `../references/cursor-agent-invocation.md` §模型选择），不许凭记忆写版本号；某一路降级时写 `X1=无（已降级：<原因>）` / `R1红队=无（红队未跑：<原因>）`，两只搜索眼都不可用写 `异构模型: 无（已降级）`
   - `事实 tiebreaker: <裁决 N 条 / 未触发 / unavailable(<原因>)>`——若跑过，把每条 verdict 与依据 URL 写进 §metadata 子段 `Phase 6 辩论历史 > 事实核查`（见 `06-debate.md` §事实核查 tiebreaker）
   - `HTML: pending`（占位，待步骤 4.5 替换）
   - `PDF: pending`（占位，待步骤 4.6 替换）
   - `Audio(概要): pending` 与 `Audio(完整): pending`（占位，待步骤 6 替换）
4.4. **终稿引用复核（Phase 6 若引入过新 URL）**：辩论 / tiebreaker 期间 incorporate 进正文的**新** URL 没经过 Phase 5.5（它跑在 Phase 6 之前）——终稿前用 `check-citations.sh` 对这些新增 URL 单独跑一遍 Layer A；dead 的按 `02-research.md` §并集的配套闸门处理（Drop + metadata 记录）。Phase 6 没引入新 URL 则跳过本步
4.5. **生成 HTML 报告**：把刚写好的 markdown 转成单文件交互式 HTML，直接按 `report-to-html` skill 的规范内联生成（**不重新触发 `/report-to-html` skill**）：
   - 读取步骤 4 写好的 `.md` 文件
   - 生成包含以下特性的单文件 HTML：
     - 顶部 sticky bar（标题 + 置信度 pill + 日期 + 打印按钮）
     - 左侧粘性目录（提取所有 `##` 章节，滚动高亮）
     - 对比表格（hover 高亮，overflow-x: auto）
     - Mermaid 流程图（如报告有流程描述）
     - Pill 状态徽章（高/中/低置信度 → pill-ok/pill-warn/pill-muted）
     - `<details>` 折叠（调研 Metadata、辩论历史等次要内容）
     - 零构建：Tailwind + Alpine + Mermaid CDN，双击即开
   - 命名：`<cwd>/<topic>-完整报告.html`（与 `.md` 同 topic + 同编号后缀）
   - 用 Write 工具落盘；用 `open "<html路径>"` 在浏览器打开验证
   - 成功：用 Edit 工具把 §metadata 中的 `HTML: pending` 替换为 `HTML: <html路径>`
   - 失败：Edit 为 `HTML: failed (<reason>)`；**不阻断主流程**，继续步骤 4.6
4.6. **生成 PDF**：调 `bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/generate-pdf.sh -o "<cwd>/<topic>-完整报告.pdf" "<cwd>/<topic>-完整报告.html"`
   - 原理：Chrome headless 打印步骤 4.5 的 HTML（复用其 print CSS，中文零字体坑）；exit 65=无 Chrome → `PDF: skipped (no chrome)`，exit 66 → `PDF: failed (<reason>)`
   - HTML 若失败/未生成 → 本步跳过，`PDF: skipped (html not generated)`
   - 成功：Edit §metadata `PDF: pending` → `PDF: <pdf路径>`；**不阻断主流程**，继续步骤 5
5. **跑 audio（两条：概要 + 完整）**：
   - **概要**：`bash generate-audio.sh -o "<cwd>/<topic>-音频概要.m4a" "<cwd>/<topic>-完整报告.md"`（内置抽取 §推荐+风险，行为不变）
   - **完整**：主 agent 先把报告**全文改写成口语稿**写到 `/tmp/survey-narration-full-<ts>.txt`（改写原则同 report-to-audio：逐章覆盖不遗漏结论；表格转成"要点串讲"；删 URL/metadata/辩论历史；数字转口语如 "45kV" → "四十五千伏"可保留阿拉伯数字但避免念符号；预期 6k-12k 字），再调 `bash generate-audio.sh -t "/tmp/survey-narration-full-<ts>.txt" -o "<cwd>/<topic>-完整音频.m4a" "<cwd>/<topic>-完整报告.md"`
   - 为什么口语稿由主 agent 写而不是脚本 strip 全文：表格与链接直接念出来不可听；主 agent 在 finalize 时上下文里就有全文，改写成本最低
   - 注意所有路径必须双引号
6. **Edit 报告 v2**：用 Edit 工具把 §metadata 中的 `Audio(概要): pending` / `Audio(完整): pending` 分别替换为最终状态：
   - 成功：`Audio(概要): <路径>` / `Audio(完整): <路径>`
   - 失败：`failed (<reason>)` 或 `skipped (<reason>)`；两条音频彼此独立，一条失败不影响另一条

### 失败降级条件分支表

五件产物各自独立降级。metadata 字段固定为这五个：
`Output` / `HTML` / `PDF` / `Audio(概要)` / `Audio(完整)`。

| 场景 | 行为 | metadata |
|---|---|---|
| 全部成功 | 全流程跑通 | `Output: <path>; HTML: <html-path>; PDF: <pdf-path>; Audio(概要): <path>; Audio(完整): <path>` |
| HTML 失败 | 不阻断；**PDF 依赖 HTML，一并 skipped**，继续两条音频 | `HTML: failed (<reason>); PDF: skipped (html not generated)`，其余照常 |
| PDF 失败（有 HTML，无 Chrome 等） | 不阻断，继续两条音频 | `PDF: failed (<reason>)`，其余照常 |
| 某条音频失败 / skipped | 两条彼此独立，一条挂不影响另一条 | 该条写 `failed (<reason>)` 或 `skipped (<reason>)`，另一条照常 |
| 报告 Write 失败（cwd 只读 / 路径无效） | **跳过 HTML / PDF / 两条音频** | 对话里 inline 输出报告 + `Output: write failed (<reason>); inline only; HTML/PDF/Audio(概要)/Audio(完整): skipped (report not written)` |

> PDF 与两条音频（概要/完整）遵循同一原则：**各自独立**降级为 `failed`/`skipped`，一个产物失败不影响其余产物，也不阻断主流程。PDF 依赖 HTML——HTML 失败时 PDF 直接 `skipped (html not generated)`。

**绝不**因 finalize 写文件失败让主流程失败——降级是设计目标，不是异常。

---

## Audio Summary（概要 + 完整两条，Phase 6 finalize 后自动跑）

> 灵感来自 Gemini Deep Research / NotebookLM。**概要**（v0）= §推荐 段摘要朗读，脚本内置抽取；**完整音频** = 主 agent 改写的全文口语稿经 `-t` 传入朗读（见 §Finalize 步骤 5）。不暗示 podcast 体验，下一步可能升级为单人 podcast-host 风格。

**触发**：Finalize 输出步骤的步骤 5 调用（在步骤 4 写报告 v1 之后、步骤 6 Edit metadata 之前）。

**执行**：

1. **主脚本**：`bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/generate-audio.sh -o "<cwd>/<topic>-音频概要.m4a" "<cwd>/<topic>-完整报告.md"`
   - 脚本支持 `-o OUT` 参数（脚本直接写到指定路径，无需主 agent mv 重命名）
   - 不传 `-o` 时默认输出 `<report>.audio.m4a`（向后兼容旧调用方）
   - 引擎：**首选 edge-tts 晓晓**（复用 `report-to-audio/scripts/tts.py --provider auto`，与对话播报 Stop hook `tts-play.sh` 同款神经嗓音）；tts.py 不可用（无 python3 / 脚本缺失）时退回 macOS `say`；非 macOS 且无 tts.py 才 skipped（exit 65 → caller 可试 openai 脚本）
   - 嗓音按语言自动选（zh→晓晓 / en→英文神经嗓音）；env var `SURVEY_AUDIO_VOICE` 覆盖嗓音，`SURVEY_AUDIO_RATE` 仅影响 `say` 兜底语速（默认 170 WPM）
   - **路径必须双引号**——应对路径含空格 / 中文 / 特殊字符

2. **可选 fallback**：`bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/generate-audio-openai.sh -o "<cwd>/<topic>-音频概要.mp3" "<cwd>/<topic>-完整报告.md"`
   - 仅当 `OPENAI_API_KEY` 环境变量存在时启用
   - 同样支持 `-o OUT` 参数
   - 主 agent 调度逻辑：先试 generate-audio.sh；非 macOS 且 `$OPENAI_API_KEY` 存在 → 试 generate-audio-openai.sh；都不成 → metadata 标 skipped

3. **降级矩阵**：见 §Finalize 输出步骤 §失败降级条件分支表（避免重复）

4. **narration 内容**：从报告抽 §推荐 整段（含结论/理由/适用条件/置信度 bullets） + §待验证风险 头 1-3 条；strip markdown 后 TTS。若 §推荐 抽不到（旧 / 非标准模板），回退到报告前 ~2000 字

**绝不**因 Audio 生成失败让主流程失败——只记 metadata 跳过。
