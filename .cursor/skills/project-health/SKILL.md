---
name: project-health
description: '系统化评估一个代码仓库的"项目健康度"——架构合理性、代码规范与精简、目录结构、冗余/无用文件、 内容隔离与解耦、技术架构、以及历史评审教训的沉淀。分四层产出报告：L0 仓库治理/供应链、 L1 静态门禁、L2 churn×complexity 趋势、L3 AI 语义+人审；可量化维度一律用可执行探针出客观 JSON， "软"维度用异构（跨模型）评审兜底，结论固化成 lint/fitness rule 与 ADR。 Use when the user says: "评估项目健康度" / "做个 codebase health / repo health" / "审一下这个仓库的架构和质量" / "查冗余文件和死代码" / "看看耦合解耦怎么样" / "代码精简度评估" / "/project-health" / "这个项目健康吗" / "技术债在哪" / "architecture / code quality audit"。 适用对象是一个 git 仓库（默认 cwd）。不是写代码、不是单 PR 评审（那用 /code-review / pre-land-review）。'
---
# /project-health — 仓库健康度评估（分层 · 可执行探针 · 异构兜底）

> 调研依据：本仓库 `项目健康度评估与可复用skill-完整报告.md`（/survey 异构调研，2026-06）。
> 设计哲学对齐用户 CLAUDE.md ②③④⑤：最小可用、外科手术式改动、**只有可执行验证才约束 agent**、**异构对抗**。

## 一句话定位

把"项目健康度"拆成**四层**，每层各司其职——别用一个分数糊弄，也别让 LLM 凭目测打分：

```
L3  人审 / AI 语义评审   架构合理性·目录结构·解耦语境·历史教训   ← 软维度，难量化 → AI + 异构 + 人审
L2  趋势 / 行为分析       churn × complexity hotspots             ← 优先级金标准（改得勤又复杂=高利息债）
L1  快照门禁             复杂度·冗余/死代码·重复·规范·MI          ← 可执行探针出客观 JSON，进 CI
L0  仓库治理 / 供应链     分支保护·依赖·license·安全策略·bus factor ← 易被"只看代码"漏掉
```

**核心断言（不可绕过）**：
- **可量化维度 → 可执行探针，不许目测**。复杂度/死代码/重复/耦合/治理 一律跑 `probes/run-probes.sh` 出 JSON。LLM 不得用"我看着挺复杂"代替工具输出。
- **软维度 → 异构评审兜底**。架构/目录/解耦"合理性"这类判断，必须经 **cursor-agent 跨模型独立 lens + 多轮辩论 + 剩余分歧人类裁决**（复用 `survey`/`debate-review` 的 Phase 6 范式）。单模型自评 = 共享盲区。
- **结论必须固化成自执行规则**。每条评审发现 → 转成 lint rule / fitness function / ADR，下次自动拦截。否则"历史教训"必然流失。
- **eval-first**：跑评估前先确认"这个仓库怎样算健康"（成功标准），见 `phases/00-scope-and-eval.md` + `eval/evaluations.md`。
- **优雅降级 + 三态诚实**：每个探针明确区分 `ran_ok` / `tool_failed`（装了但报错，带 exit code + stderr）/ `skipped`（没装，给安装指令）——**装了却崩的工具绝不当成 skip 或 pass**。核心探针仅需 `git + python3 + jq`（`churn_hotspots.py` 更是纯 git+python 零依赖）；第三方工具缺失只降覆盖、不阻断。

---

## 工作流总览

```
Phase 0  界定范围 + eval-first       [Read phases/00-scope-and-eval.md]
  → L0   仓库治理 / 供应链            [Read phases/L0-governance.md]      ┐
  → L1   静态门禁（探针）             [Read phases/L1-static-gates.md]    │ 多为 run-probes.sh 一次产出
  → L2   churn×complexity 趋势        [Read phases/L2-trends.md]          ┘
  → L3   AI 语义评审 + 异构终审       [Read phases/L3-semantic.md + prompts/*]   ← 强制 Read gate
  → 99   综合 + 固化规则 + 落报告      [Read phases/99-synthesize-and-finalize.md]
```

L0/L1/L2 的可执行部分**一条命令**就能跑完：

```bash
bash probes/run-probes.sh --repo <目标仓库> [--out <outdir>] [--npx] [--pipx]
# 仅需 git+python3+jq 即产出 hotspots + 治理 + secret 扫描；node 工具加 --npx，python 工具加 --pipx
# --out 默认落到仓库外（避免探针产物污染 scc/jscpd/depcruise 扫描）；--npx/--pipx 会拉远程包，manifest 标 network_code_execution
```

L3 不是探针能替代的——架构是否"合理"、目录是否"该这么分"、解耦是否"到位"需要语义判断，**这才是异构评审存在的理由**。

---

## Phase / Prompt Read Gate（硬约束，不可凭记忆"演"）

> 背景同 survey：长对话里 skill 指令会衰减（anthropics/skills #591）。进入每个 Phase / 用每个 prompt 前**必须 Read** 对应文件，禁止凭印象重建。

| 阶段 | 必读文件 | 强制 gate 语句 |
|---|---|---|
| Phase 0 | `phases/00-scope-and-eval.md` + `eval/evaluations.md` | `Read both; state "Loaded Phase 0 + evals"` |
| L0 | `phases/L0-governance.md` | `Read it; state "Loaded L0"` |
| L1 | `phases/L1-static-gates.md` + `rubric/thresholds.md` | `Read both; state "Loaded L1 + thresholds"` |
| L2 | `phases/L2-trends.md` | `Read it; state "Loaded L2"` |
| L3 | `phases/L3-semantic.md` + `prompts/L3-semantic-review.txt` | `Read both; state "Loaded L3 + semantic prompt"` |
| L3 异构终审 | `prompts/heterogeneous-final.txt` + `run-cursor-agent.sh` | `Read both; state "Loaded heterogeneous review"` |
| 99 综合 | `phases/99-synthesize-and-finalize.md` + `rubric/dimensions.md` + `report-template/report-template.md` | `Read all; state "Loaded synthesis"` |

**文件缺失处理**：Read 失败 → 停止该阶段并报告；不允许"演"内容继续。

---

## 七个关注点 → 落在哪层（直接回答"覆盖完整性"）

| 关注点 | 层 | 主要手段 |
|---|---|---|
| 架构及框架合理性 | L1+L3 | fitness functions（dependency-cruiser/ArchUnit/import-linter）+ AI 语义评审 |
| 代码规范，代码精简 | L1 | ESLint/Ruff + radon/lizard/scc 复杂度 + Maintainability Index |
| 目录结构合理性 | L1+L3 | dependency-cruiser orphans/边界 + rubric + AI 评审 |
| 冗余文件，无用文件 | L1 | knip / vulture / deadcode + jscpd 重复 |
| 内容隔离，解耦 | L1+L2 | no-circular + instability + 分层规则 + hotspots |
| 技术架构合理性 | L2 | churn×complexity hotspots + MI 趋势 |
| 历史评审的经验教训 | 流程 | ADR/MADR → 固化成 lint/fitness rule（见 phases/99） |

> 详细 rubric + 阈值见 `rubric/dimensions.md` / `rubric/thresholds.md`。

---

## 强制 invariants（SKILL.md 内保留，不只放 phase）

1. **四层全覆盖**：L0/L1/L2/L3 缺一不可；某层探针全 skip 也要在报告里显式标"该层未自动覆盖 + 安装指令"，不得静默跳过。
2. **可执行优先**：能跑工具量化的维度，报告里必须引 `probes.json` 的客观数字，不得只写 LLM 主观判断。
3. **L3 异构终审强制**：架构/解耦/目录这类软结论必须经 cursor-agent 跨模型评审 + 主 agent 判断矩阵 + 剩余分歧人类裁决。cursor-agent 不可用 → 报告顶部 banner 标注"软维度未经异构审查，高风险结论需人工复核"，**绝不**因此让主流程失败。
4. **固化闭环**：每条 actionable 发现给出"如何变成自执行规则"（lint/fitness/ADR），否则视为未完成。
5. **fail-closed 于安全**：探针发现 committed secret / 依赖漏洞 / 无分支保护 等，标红并要求人工确认，不静默放行。

---

## 文件结构

```
project-health/
├── SKILL.md                         # 本文件：索引 + 硬 invariants + Read gate
├── phases/
│   ├── 00-scope-and-eval.md         # 界定范围 + 检测技术栈 + eval-first 成功标准
│   ├── L0-governance.md             # 仓库治理 / 供应链
│   ├── L1-static-gates.md           # 静态门禁（复杂度/死代码/重复/规范/MI）
│   ├── L2-trends.md                 # churn × complexity hotspots
│   ├── L3-semantic.md               # AI 语义评审 + 异构终审 + 多轮辩论 + 人类裁决
│   └── 99-synthesize-and-finalize.md# 综合评分 + 固化规则 + 落报告/HTML
├── rubric/
│   ├── dimensions.md                # 7+1 维度 rubric + 评分口径
│   └── thresholds.md                # 量化阈值表（冻结）
├── probes/
│   ├── run-probes.sh                # 探针编排器（L0-L2，优雅降级，出 probes.json）
│   └── churn_hotspots.py            # 自包含 churn×complexity（纯 git+python，零安装）
├── prompts/
│   ├── L3-semantic-review.txt       # L3 AI 语义评审 prompt（Read gate）
│   └── heterogeneous-final.txt      # cursor-agent 异构终审 prompt（Read gate）
├── report-template/
│   └── report-template.md           # 健康度报告模板
├── eval/
│   └── evaluations.md               # eval-first：≥3 场景 + 期望行为
└── run-cursor-agent.sh              # cursor-agent 调用 helper（同 survey）
```

---

## 触发与边界

**触发**（任意命中）："评估项目健康度" / "repo / codebase health" / "审一下这个仓库" / "查死代码冗余文件" / "解耦/耦合怎么样" / "技术债在哪" / "/project-health"。

**边界（不做）**：
- **不写业务代码、不重构**——只评估 + 给固化建议；实施交给 /feature-fullstack 或用户。
- **不是单 PR 评审**——那是 `/code-review`、`pre-land-review`、`/security-review` 的活；本 skill 评的是**整仓库**的健康度。
- **不替你定义"什么叫健康"**——阈值在 `rubric/thresholds.md` 可调；跑前用 Phase 0 eval-first 对齐。
- **不无脑装工具**——探针缺失就给安装指令，是否装由用户决定。

## 与相关 skill 的区别

| skill | 适用 |
|---|---|
| `/project-health` | 整仓库健康度评估（架构/规范/解耦/死代码/治理/历史教训），分层 + 可执行 + 异构 |
| `/code-review`·`pre-land-review` | 单个 diff / PR 的逐行评审 |
| `/security-review` | 安全专项 |
| `/survey` | 调研外部最佳实践（本 skill 的设计就来自一次 /survey） |
| `/debate-review` | 对外部 AI 评审做结构化辩论裁决（本 skill L3 复用其范式） |
