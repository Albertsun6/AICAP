---
name: search-online-skills
description: >-
  到「线上」搜是否已有现成 agent/Claude skill 满足某个能力——跨多个 skill 市场（官方 +
  社区 + 聚合 awesome 列表 + skills.sh 注册表）+ GitHub 代码搜索 + 全网广搜，逐个对抗式
  核实「确实存在且真做这件事」，按相关度与质量信号（installs / stars / 官方）排序，输出对比表。
  只读不安装（要装交给 /install-skill；查不到给 /skill-creator 自建）。
  查找源动态维护：版本化种子注册表 + 每次运行联网发现新市场 + 用户确认后回写。
  触发：搜索线上 skill / 网上有没有做 X 的 skill / 去市场找 X 的 skill / 线上找个现成 skill /
  有没有现成 skill 能 X / search online for a skill / is there an online skill for X
  （强调"线上 / 现成 / 市场"，要广搜多源而不只是问某一个 CLI）。
targets: ["*"]
---

# search-online-skills

到**线上多个来源**搜「有没有现成的 skill 能做某事」，核实后排序给结论。**只读、不安装**。

## 为什么单独存在（与已有两个 skill 的边界）

| skill | 干什么 | 局限 |
|---|---|---|
| `find-skills` | 走 `npx skills find` + skills.sh 排行榜 | **只覆盖 skills.sh 这一个注册表** |
| `install-skill` | 浏览**固定 4 个**已知市场目录 → 选 → 装进 SSOT | 以**装**为主，源写死、不跨全网 |
| **本 skill** | **能力驱动**地跨「官方市场 + 社区 + 聚合列表 + 注册表 + GitHub 代码搜索 + 全网」广搜并核实排序 | 只到「给结论」为止，**装**再转 `/install-skill` |

一句话：`find-skills` 问一个注册表、`install-skill` 管安装，本 skill 是**跨源广搜 + 核实 + 排序的发现层**。要装就把选中的 slug 交给 `/install-skill`。

## 常量

```
SKILL_DIR = ~/Desktop/AICAP/.rulesync/skills/search-online-skills
SOURCES   = $SKILL_DIR/sources.yaml        # 源注册表（种子 + 发现探针），SSOT
SSOT_ROOT = ~/Desktop/AICAP
```

## 执行流程

### Step 0 — 把需求收敛成「能力查询」

- 用户给的是模糊能力（如「项目可视化」）→ 拆成**关键词 + 同义词**：visualize / diagram / dependency graph / codebase map / architecture / 结构图…（中英都列，市场以英文为主）。
- 含糊就先问一句要哪种（如可视化要「报告型 mermaid」还是「自动依赖图」），别静默挑一个。

### Step 1 — 载入源注册表

读 `sources.yaml`：拿到 `sources`（种子市场，含 `list_via` 怎么列）和 `discovery_probes`（怎么发现新源）。**源不写死在本文档里，全在 yaml**——这是「动态维护」的落点。

### Step 2 — 联网发现新源（动态维护 ①）

跑 `discovery_probes` 里的 GitHub 仓库搜索 + 读聚合/awesome 列表 + 全网搜，得到一批**候选市场仓库**；与 `sources` 比对，挑出注册表里**还没有**的。新源**本轮即纳入搜索范围**（先用上，不必等回写）。记下来供 Step 6 回写。

### Step 3 — 跨源广搜（fan-out）

对每个源（种子 + 本轮新发现）并行执行 `list_via`，列出 skill 目录并读其 `SKILL.md` 的 `description`；同时跑：
- **GitHub 代码搜索**：`gh search code --filename SKILL.md "<关键词>"`、`gh search repos <关键词>`
- **skills.sh**：`npx --yes skills find "<query>"`（失败回退 WebFetch `https://skills.sh/?q=`）
- **全网**：WebSearch + WebFetch 兜住前两者漏掉的

> 彻底模式（默认，能力含糊或要穷尽时）：用 **Workflow** 把上面几路 fan-out 成并行 agent，再 pipeline 进 Step 4 核实——参考本仓 `survey` / 主循环 `find-online-viz-skill` 工作流的写法。
> 快速模式（用户只想扫一眼某个明确市场）：内联跑 2–3 条 `list_via` + 一次 `gh search` 即可。

### Step 4 — 对抗式核实（别信 description 一面之词）

对每个候选，打开它的 SKILL.md / 页面，判定：
- **exists**：真实可达？
- **really_does_it**：是不是**真做**用户要的事（不是只在 description 里提了一嘴）？默认存疑——证不出就判 false。
- **quality_signal**：installs / stars / 是否官方源。
- **caveats**：可移植性（用了 Claude 专有 hook / `allowed-tools` 在 Cursor/Codex 会退化）、license（document-skills 类为 source-available）。

> 遵守全局 ⑤ 异构验证：关键结论（尤其"这个 skill 真能做 X"）尽量用**可执行证据**（实际读到 SKILL.md 正文里的步骤）而非"看名字像"。拿不准标 low confidence，别替用户拍板。

### Step 5 — 排序 + 输出对比

按 `相关度 × 质量信号（trust + installs/stars + 官方优先）`排序，输出一张表：

```
排名 | skill | 源(trust) | 它到底怎么做这件事 | 质量信号 | 安装命令 | 备注/坑
```

没有命中就**如实说没有**，进 Step 6 的「自建」分支。别硬凑。

### Step 6 — 收尾（三个出口 + 动态维护 ②）

- **要安装** → 把选中的 `<org/repo@slug>` 交给 `/install-skill`（本 skill 不写本地、不装）。
- **没找到** → 提议用 `/skill-creator` 自建一个，并说清自建大概要什么。
- **发现了值得长期保留的新源**（Step 2 的产物）→ 列给用户，**确认后**追加进 `sources.yaml` 的 `sources:`，再 `cd $SSOT_ROOT && pnpm run ai:generate`。这就是「查找源动态维护」的闭环——源随用随长，且全程在 SSOT 里版本化。

## 约束

- **只读**：本 skill 不安装、不写除 `sources.yaml` 外的任何文件；装的动作一律转 `/install-skill`。
- **回写要确认**：动 `sources.yaml` 前把将加的源列出来等用户点头，别静默改 SSOT。
- **GitHub 认证**：`gh` 调用前若 `gh auth status` 失败，提示 `gh auth login`；被限流就回退 WebFetch。
- **公平 + 留痕**：核实先 steelman 再挑刺；判 false 要给出"我查了哪、为什么不算"。
- **不夸大**：质量信号查不到就写"未知"，不要编 install 数 / star 数。
