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

Phase 2 结束后启动综合 Agent，读取 A+B+X（默认）或 A+B+C（cursor-agent 不可用 fallback）的独立发现，构建合并矩阵，并标注三方分歧点。

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

- **Phase 6 异构终审 verdict**: <Concur / Refine / Dissent>
- **辩论收敛**: <Concur 直通 / 自动收敛 Round N / 人类裁决终止 Round 3+>
- **人类介入**: <无 / 用户裁决 K 条>
- **Output**: <cwd 报告路径 或 `write failed (<reason>); inline only`>
- **Filename collision**: <none / detected, saved as <final-path>>
- **Audio**: <path 或 `pending`（v1 占位）/ `skipped (<reason>)` / `failed (<reason>)`>

#### Phase 6 辩论历史（仅 Refine / Dissent 时；只放 metadata，不进正文推荐区）

##### Round 1：主 agent 判断矩阵
| 建议 | 立场 | 论据 / 证据 |
|---|---|---|
| <reviewer 建议简述> | accept \| partial \| defer \| refute（refute 必附 `reason: unsupported \| contradicted`） | 一句话；contradicted 必附 URL |

##### Round 2（如有未 accept 的建议）：cursor-agent rebuttal + 主 agent 二轮判断
| 建议 | cursor-agent 反驳要点 | 主 agent 立场（维持 / 让步） | 论据 |
|---|---|---|---|

##### Round 3（如 Round 2 后仍有分歧）：cursor-agent 二次 rebuttal + 主 agent 三轮判断
| 建议 | cursor-agent 二次反驳 | 主 agent 立场 | 论据 |
|---|---|---|---|

##### 人类裁决（仅 Round 3 后仍有分歧时）
| 建议 | 主 agent 最终立场 | cursor-agent 最终立场 | 用户裁决 | 用户备注 |
|---|---|---|---|---|
```

---

## Finalize 输出步骤（Phase 6 收敛后、Audio 之前强制执行）

> 原则：最终报告 + HTML + audio 默认落到 cwd（用户启动 Claude Code 时所在目录），不再只在对话里 markdown 输出。中间产物（prompt / subagent 输出 / citation JSON）继续留 /tmp。

### 触发时机（**唯一触发点**）

- Phase 6 §收敛检查全部通过：**Round 1 Concur** / **Round 2/3 双方同档（无分歧）** / **人类裁决完成**
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
2. **拼装 cwd 路径**：从 Bash `pwd` 取 cwd，拼出三个目标路径：
   - `<cwd>/<topic>-完整报告.md`
   - `<cwd>/<topic>-完整报告.html`
   - `<cwd>/<topic>-音频概要.m4a`
3. **同名冲突处理**：用 Bash 检测 `.md` 目标文件是否存在（`.html` 与 `.m4a` 沿用相同 topic + 后缀，自动跟随 `.md` 的最终编号）
   - 不存在 → 直接写；§metadata 写 `Filename collision: none`
   - 存在 → 尝试 `-2`、`-3`、`-4` 累加后缀直到不冲突；§metadata 写 `Filename collision: detected, saved as <final-path>`
   - **不覆盖、不询问**——保留旧调研产物
4. **写报告 v1**：用 Write 工具落综合 markdown 到目标路径，§metadata 中：
   - `Output: <最终路径>`
   - `HTML: pending`（占位，待步骤 4.5 替换）
   - `Audio: pending`（占位，待步骤 6 替换）
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
   - 失败：Edit 为 `HTML: failed (<reason>)`；**不阻断主流程**，继续步骤 5
5. **跑 audio**：调 `bash generate-audio.sh -o "<cwd>/<topic>-音频概要.m4a" "<cwd>/<topic>-完整报告.md"`，注意所有路径必须双引号
6. **Edit 报告 v2**：用 Edit 工具把 §metadata 中的 `Audio: pending` 替换为最终状态：
   - 成功：`Audio: <音频文件路径>`
   - 失败：`Audio: failed (<reason>)` 或 `Audio: skipped (<reason>)`

### 失败降级条件分支表

| 场景 | 行为 | metadata |
|---|---|---|
| 报告 Write 成功 + HTML 成功 + audio 成功 | 全流程跑通 | `Output: <path>; HTML: <html-path>; Audio: <audio-path>` |
| 报告 Write 成功 + HTML 失败 + audio 成功 | HTML 不阻断流程，继续 audio | `Output: <path>; HTML: failed (<reason>); Audio: <audio-path>` |
| 报告 Write 成功 + HTML 成功 + audio 失败 | Edit audio 为 failed | `Output: <path>; HTML: <html-path>; Audio: failed (<reason>)` |
| 报告 Write 成功 + HTML 成功 + audio skipped | Edit audio 为 skipped | `Output: <path>; HTML: <html-path>; Audio: skipped (<reason>)` |
| 报告 Write 失败（cwd 只读 / 路径无效） | **跳过 HTML 和 audio** | 对话里 inline 输出报告 + `Output: write failed (<reason>); inline only; HTML: skipped (report not written); Audio: skipped (report not written)` |

**绝不**因 finalize 写文件失败让主流程失败——降级是设计目标，不是异常。

---

## Audio Summary（摘要朗读 v0，Phase 6 finalize 后自动跑）

> 灵感来自 Gemini Deep Research / NotebookLM；当前实现是 §推荐 段的摘要朗读 (v0)，不暗示 podcast 体验。下一步可能升级为单人 podcast-host 风格。

**触发**：Finalize 输出步骤的步骤 5 调用（在步骤 4 写报告 v1 之后、步骤 6 Edit metadata 之前）。

**执行**：

1. **主脚本**：`bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/generate-audio.sh -o "<cwd>/<topic>-音频概要.m4a" "<cwd>/<topic>-完整报告.md"`
   - 脚本支持 `-o OUT` 参数（脚本直接写到指定路径，无需主 agent mv 重命名）
   - 不传 `-o` 时默认输出 `<report>.audio.m4a`（向后兼容旧调用方）
   - 跨平台检测（uname + command -v say）；非 macOS 直接 skipped
   - 默认不指定 voice（系统默认）+ rate 170 WPM；env var `SURVEY_AUDIO_VOICE` / `SURVEY_AUDIO_RATE` 可 override
   - **路径必须双引号**——应对路径含空格 / 中文 / 特殊字符

2. **可选 fallback**：`bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/generate-audio-openai.sh -o "<cwd>/<topic>-音频概要.mp3" "<cwd>/<topic>-完整报告.md"`
   - 仅当 `OPENAI_API_KEY` 环境变量存在时启用
   - 同样支持 `-o OUT` 参数
   - 主 agent 调度逻辑：先试 generate-audio.sh；非 macOS 且 `$OPENAI_API_KEY` 存在 → 试 generate-audio-openai.sh；都不成 → metadata 标 skipped

3. **降级矩阵**：见 §Finalize 输出步骤 §失败降级条件分支表（避免重复）

4. **narration 内容**：从报告抽 §推荐 整段（含结论/理由/适用条件/置信度 bullets） + §待验证风险 头 1-3 条；strip markdown 后 TTS。若 §推荐 抽不到（旧 / 非标准模板），回退到报告前 ~2000 字

**绝不**因 Audio 生成失败让主流程失败——只记 metadata 跳过。
