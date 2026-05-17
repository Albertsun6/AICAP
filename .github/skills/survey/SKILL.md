---
name: survey
description: |
  针对任意话题，系统性地调研网上别人的做法、结构化比较方案、评估优劣、给出建议。
  比 borrow-open-source 更通用——不限于开源代码，适用于任何选型、方案研究、最佳实践调查。

  Use when the user says:
  "了解一下别人怎么做X" / "调研X方案" / "网上有哪些做X的方式" / "比较X和Y"
  "X的最佳实践" / "benchmark X" / "别人怎么解决X问题" / "/survey X"

  Phase 2 用 2 个 Claude agent + 1 个 cursor-agent (GPT-5.5-medium) 并行异构搜索，
  综合后再用 cursor-agent 跑一遍异构终审，最多 3 轮辩论后剩余分歧由人类裁决。
  对抗 Claude 训练数据集体盲区。cursor-agent CLI 不可用时自动降级到 3 Claude 并在
  报告顶部 banner 提示——但用户不能主动跳过任何阶段。
  /survey 无 flag——只有一条高质量路径，每个阶段都是质量门禁。
---
# /survey — 调研·比较·建议

## 工作流总览

```
Phase 1 问题界定
  → Phase 1.5 Brief                        [Read prompts/brief-template.txt]
  → Phase 2 (2 Claude + 1 cursor-agent     [Read prompts/agent-x.txt]
             并行异构搜索)
  → Phase 2.5 Reflection Gate
  → Phase 3-5 综合                          [生成报告]
  → Phase 5.5 Citation Health
  → Phase 6 cursor-agent 异构终审            [Read prompts/round1.txt]
  → 多轮辩论（最多 3 轮）                     [Read prompts/round{2,3}-rebuttal.txt]
  → 剩余分歧人类裁决
  → Finalize: 写报告 + HTML + audio 到 cwd      [Write <cwd>/<主题>-完整报告.md]
  → HTML report (step 4.5, after .md)          [Write <cwd>/<主题>-完整报告.html（交互式单页）]
  → Audio summary (after finalize, once)       [bash generate-audio.sh -o <cwd>/<主题>-音频概要.m4a (脚本 -o 直写)]
```

**为什么默认就走异构 + 终审**：对抗 **Claude 训练数据集体盲区**——Claude 倾向把训练集里熟悉的工具/方法排在前面，可能漏掉训练截点后出现的新选项、非 Anthropic 生态的方案、低星但成熟的工业方案。3 个 Claude agent 并行只对抗"搜索范围偏差"，对抗不了模型层面共享的盲区。默认开启异构 = 默认假设你在用 /survey 调研对你重要的事情。**无 opt-out flag**——/survey 只有一条高质量路径。

**自动降级**：cursor-agent CLI 不可用 / 调用失败时，系统自动退化（详见 `phases/02-research.md` §cursor-agent 不可用时的自动降级）；用户无法主动选择跳过任何阶段。

---

## Prompt Template Read Gate（硬约束，不可绕过）

> **背景**：[anthropics/skills issue #591](https://github.com/anthropics/skills/issues/591) 指出长对话中 skill instructions 会衰减——LLM 容易凭模糊记忆"演"prompt 模板内容。/survey 把 prompt 模板抽到 `prompts/*.txt`，**必须强制 Read** 才能保证质量门禁。

进入以下阶段**前**，主 agent 必须 Read 对应 prompt 文件（禁止凭记忆重建）：

| 阶段 | 必读 prompt 文件 | 强制 gate 语句 |
|---|---|---|
| Phase 1.5 Brief | `prompts/brief-template.txt` | `Read brief-template.txt; state "Loaded Brief template"` |
| Phase 2 Agent X | `prompts/agent-x.txt` | `Read agent-x.txt; state "Loaded Agent X prompt"` |
| Phase 6 Round 1 | `prompts/round1.txt` | `Read round1.txt; state "Loaded Round 1 prompt"` |
| Phase 6 Round 2 | `prompts/round2-rebuttal.txt` | `Read round2-rebuttal.txt; state "Loaded Round 2 prompt"` |

**模板缺失处理**：如果文件不存在或 Read 失败，**停止该阶段**并报告错误；不允许"演"模板内容继续。

---

## Phase Read Gate（硬约束，不可绕过）

每个 Phase 启动**前**必须 Read 对应 phase 文件（不要凭整体印象"演"流程）：

| Phase | 必读 phase 文件 | 强制 gate 语句 |
|---|---|---|
| 1 + 1.5 | `phases/01-question-framing.md` | `Read phases/01-question-framing.md; state "Loaded Phase 1+1.5"` |
| 2 | `phases/02-research.md` + Agent X prompt | `Read phases/02-research.md; state "Loaded Phase 2"` |
| 2.5 | `phases/03-reflection.md` + `references/source-quality.md` | `Read both; state "Loaded Phase 2.5 + Source Quality"` |
| 3-5 + Audio | `phases/04-synthesis.md` | `Read phases/04-synthesis.md; state "Loaded Phase 3-5 + Audio spec"` |
| 5.5 | `phases/05-citation.md` | `Read phases/05-citation.md; state "Loaded Phase 5.5"` |
| 6 | `phases/06-debate.md` + Round 1/2 prompts | `Read phases/06-debate.md + round prompts; state "Loaded Phase 6"` |

**为什么 SKILL.md 不能太薄**：以下硬性 invariants 必须保留在 SKILL.md 内（不光放 phase 文件）：
- 异构搜索强制（Phase 2 必须 2 Claude + 1 cursor-agent）
- Phase 6 多轮辩论 + 人类裁决强制（高质量 only，无 opt-out）
- cursor-agent 不可用时自动降级 + banner（fallback contract）
- 信源排除（不搜中文社区）
- 每个 phase / prompt 进入前的强制 Read gate

---

## 文件结构

```
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/
├── SKILL.md                       # 本文件：索引 + 硬 invariants + Read gate
├── phases/
│   ├── 01-question-framing.md     # Phase 1 + 1.5 Brief
│   ├── 02-research.md             # Phase 2 三方异构搜索 + fallback + cursor-agent 调用
│   ├── 03-reflection.md           # Phase 2.5 Reflection Gate
│   ├── 04-synthesis.md            # Phase 3-5 综合 + 报告 + Audio overview
│   ├── 05-citation.md             # Phase 5.5 Citation Health Layer A + B
│   └── 06-debate.md               # Phase 6 多轮辩论 + 人类裁决
├── references/
│   ├── source-quality.md          # Source Quality Helper（被 Phase 2/2.5/5.5/6 共用）
│   └── cursor-agent-invocation.md # cursor-agent 调度 4 硬点 + exit code（被 Phase 2/6 共用）
├── prompts/
│   ├── brief-template.txt         # Phase 1.5 Brief 模板
│   ├── agent-x.txt                # Phase 2 Agent X cursor-agent 模板
│   ├── round1.txt                 # Phase 6 Round 1 终审 prompt
│   └── round2-rebuttal.txt        # Phase 6 Round 2 rebuttal prompt
├── check-citations.sh             # Phase 5.5 Layer A 脚本
├── run-cursor-agent.sh            # cursor-agent 子进程调用
├── generate-audio.sh              # Audio overview 主脚本 (macOS `say`，支持 -o OUT)
└── generate-audio-openai.sh       # Audio overview 可选 fallback (OpenAI TTS，支持 -o OUT)
```

---

## 触发与标志

**触发**（用户任意说以下内容均可）：
- "了解一下别人怎么做X"
- "调研X方案 / 调研一下X"
- "比较X和Y / X和Y哪个好"
- "X的最佳实践是什么"
- "benchmark X"
- "/survey X"

**行为**：始终走全流程（Phase 1 → 1.5 → 2 → 2.5 → 3-5 → 5.5 → 6 多轮辩论 + 人类裁决 → Audio overview）。**无 flag**——/survey 是高质量调研 skill，每个阶段都是质量门禁。需要快速概览请用其他 skill 或直接问 Claude，不要用 /survey。

---

## 边界（不做的事）

- **不写代码**：survey 只做研究，实施交给其他 skill 或用户
- **不无限抓取**：每个来源最多 fetch 2 页，保持聚焦
- **不强制有答案**：数据不足时明确说"数据不足，建议验证"，不填空分

## 输出文件位置（finalize 时强制）

- **最终报告 + HTML + audio → cwd**（用户启动 Claude Code 时所在目录）
  - 报告：`<主题>-完整报告.md`（主题由主 agent 从研究问题提取 8-15 字中文 / 英文短语）
  - HTML：`<主题>-完整报告.html`（交互式单页，含粘性目录 / Mermaid 图 / 置信度 pill，双击即开）
  - Audio：`<主题>-音频概要.m4a`（macOS）或 `.mp3`（OpenAI TTS）
  - 同名冲突：`.md` / `.html` / `.m4a` 三者同步累加 `-2` `-3` 后缀（不覆盖旧文件、不询问）
- **中间产物 → /tmp**：agent prompt 文件（`/tmp/survey-prompt-<ts>.txt`）、subagent 输出（`/tmp/survey-output-<ts>.md`）、Round 1/2/3 prompt 与输出、Citation health JSON 全部留 /tmp，不污染 cwd
- 详细 finalize 流程见 `phases/04-synthesis.md` §Finalize 输出步骤

---

## 与相关 Skill 的区别

| Skill | 适用场景 |
|---|---|
| `/survey` | 任意话题调研，通用，重研究+比较+建议 |
| `/borrow-open-source` | 专门研究开源代码，目标是借鉴到自己的项目 |
| `/harness-review-workflow` | 你已有方案/设计，需要多 AI 评审 |

---

## 借鉴来源（设计参考，非执行步骤）

- **Brief as north star**（Phase 1.5）：LangChain Open Deep Research `write_research_brief` 节点
- **Compressed Findings + Source Inventory 二段式**（Phase 2 #5）：LangChain ODR `compress_research`；Anthropic 工程 blog (2025-06-13) "isolated context windows is biggest single win"
- **Source Quality 启发式评分**（#8）：Tavily / Exa source signal；DeepResearch Bench unique-domain count
- **Reflection Gate**（Phase 2.5 #3）：LangChain ODR `think_tool` / Local Deep Researcher `reflect_on_summary` / Self-RAG 反射 token (arxiv 2310.11511)
- **Citation Health Layer A + B**（Phase 5.5 #4）：DeepResearch Bench FACT framework / arxiv 2604.03173（URL hallucination）/ arxiv 2605.06635（cited but not verified）/ CiteAudit
- **异构多轮辩论 + 人类裁决**（Phase 6）：Heterogeneous Multi-Agent Debate (KSU JCIS 2025) / Multi-Agent Debate (Du et al. arxiv 2305.14325) / Anthropic Skills issue #591 long-conversation instruction decay
- **Audio summary**（Phase 6 finalize 后）：灵感来自 Gemini Deep Research / NotebookLM；当前实现是 §推荐 段摘要朗读 v0，下一步可能升级为单人 podcast-host 风格

---

## Troubleshooting / FAQ

**为何用 cursor-agent CLI 而非 OpenAI/Gemini API**：cursor-agent 走用户已有的 Cursor 订阅（零额外配置、不另外计费），API 方案需要 `OPENAI_API_KEY` 配置 + token 计费。未来如收到不装 cursor-agent 的用户反馈，再考虑加 API fallback。

**Audio 在非 macOS 上怎么办**：`generate-audio.sh` 自动检测，非 macOS 直接 skipped。若 `OPENAI_API_KEY` 已 export，主 agent 调度 `generate-audio-openai.sh` 作为可选 fallback。
