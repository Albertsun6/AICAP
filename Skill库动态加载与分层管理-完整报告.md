# Skill 库动态加载与分层管理 — 调研报告与建议方案

> 面向有经验的工程师 · 价值观对齐 CLAUDE.md：② 最简优先、反对过度工程，⑤ 异构验证、可证伪。
> 方法：4 路并行异构调研 + 对抗验证（关键主张跑 CONFIRMED / REFUTED）。基线数据已在本机复核（2026-06-13）。
> 本报告分三部分：① 机制与判断（回答"动态加载"）；② 面向规模化的库建设蓝图（回答"建自己的库 + 全生命周期"）；③ 落地路线图与风险。

---

## 0. 一句话结论（TL;DR）

1. **「skill 太多要做动态加载」是个伪命题——正文的动态加载是框架自带的，你不用造。**（对抗验证 **CONFIRMED**）Claude Code 启动时**只把每个 skill 的 `name+description` 元数据放进上下文**，SKILL.md 正文与 bundled 文件**只在该 skill 被触发时才加载**（三级渐进披露）。你这 25 个 skill 的正文（SSOT 20 个 body 合计约 178K 字符，最大 plan-ceo-review 约 49K）**本来就不在常驻上下文里**。机制层无需任何改造。

2. **真正常驻的只有元数据之和，而且现在很便宜——约 2.5–3.1K token，占 200K 窗口 < 2%，占 1M 窗口 < 0.3%。** 为这个量级自建路由 / 检索 / MCP 索引 = 为不存在的瓶颈付出新增故障面，是过度工程。

3. **拐点不在 token，触发准确度先死。** 业界实证一致：相似工具会让"选对率"显著下降（hard-negative 下从 ~94% 掉到 ~70%；工具选择错误占 agent 失败约 44%；10+ 相似工具即 choice overload）。你可能在 always-on 只占 4% 时，就已经经常被**选错 skill**。你库里已有 4 个明显重叠簇（评审 6 个、commit/sync 3 个、调研 4 个、报告输出 3–4 个）。

4. **你要的"分层按类、做不同事调不同类"在 Claude Code 里不是运行时 OOP 调度，是三个静态维度配好：** 职能分类（给人 + `/` 菜单）× 作用域（决定哪个项目里常驻）× 触发型（`disable-model-invocation` 决定是否占常驻预算）。把这三维配好，框架的渐进披露 + 作用域 + LLM 路由替你做调度。

5. **面向"后期上百 skill"的正确策略：地基现在打满，重型加载基础设施按 skill 数阈值再上。** 路由 / RAG / MCP 索引在 ~100 skill 以下是过度抽象；真正该现在投资的是**零基础设施却锁住未来所有档位触发准确度的钱**：命名前缀 + 差异化描述 + 把 eval 纳入新增 skill 的门禁。

6. **一个被对抗验证修正的关键点：路由 / 索引 skill 不能降低 always-on 成本**——顶层路由自身 description 必须常驻，被它"隐藏"的子 skill 只要还在 `~/.claude/skills/` 顶层，元数据照样常驻。真正能减 footprint 的只有：把 skill 移出发现路径（作用域隔离 / 不软链）或 `skillOverrides: "off"` / `disable-model-invocation`。**另：Claude Code 只扫描 `~/.claude/skills/` 顶层，嵌套子目录不会被自动发现——别用建子目录来分类，会让 skill 直接消失。**

7. **顺手发现一个真 bug：** `short-drama/SKILL.md` 首行是 `# /short-drama` 而非合法 YAML frontmatter，靠 harness 兜底才被发现。优先修。

---

# 第一部分 · 机制与判断（回答"动态加载"）

## 1. Claude Code 技能是怎么加载的（机制澄清）

### 1.1 三级渐进披露（哪级常驻、哪级按需）

| 层级 | 内容 | 何时加载 | 是否常驻 | 单位成本 | 置信度 |
|---|---|---|---|---|---|
| **L1 元数据** | frontmatter 的 `name` + `description` | 会话启动时 | **是（always-on）** | 官方标称 ~100 token/skill；AICAP 实测中文偏长，均约 130，最胖近 290 | high（CONFIRMED） |
| **L2 指令体** | SKILL.md 正文 | 该 skill 被触发时（`/name` 或模型匹配 description） | 否 | 通常 < 5K token | high（CONFIRMED） |
| **L3 资源** | `references/`、`scripts/`、示例等引用文件 | 被正文具体引用时 | 否 | 脚本只回传 stdout，代码不进上下文 | high |

关键证据（CONFIRMED）：官方 Context Window 文档明确"完整 skill 内容只在 Claude 实际使用时才加载"，且这份元数据清单"在 `/compact` 后不会重新注入"——证明正文根本不在初始启动上下文里。

> 已知不一致（中等置信）：GitHub issue #14882 报告**某些 skill 会在启动时加载完整 body 而非仅元数据**。建议落地前在本机用 `/doctor` 或实测上下文占用核对一次，别只信文档标称。

### 1.2 发现路径与作用域（优先级 高→低）

1. **Enterprise / Managed**：系统级，组织全员生效。
2. **Personal `~/.claude/skills/`**：用户级，**所有项目**常驻。← 你现在 25 个全在这。
3. **Project `.claude/skills/`**：**仅当前 repo**（从启动目录向上搜到仓库根）。← **这是"按项目加载"的官方杠杆。**
4. **Plugin `<plugin>/skills/`**：插件命名空间，仅插件启用时加载。
5. **`--add-dir` 指向目录**内的 `.claude/skills/` 也会被加载（可临时挂一组）。

> 重要限制（high）：Claude Code **只扫描 `~/.claude/skills/` 顶层目录**找 SKILL.md。**嵌套子目录不被自动发现**（issues #18192 / #28266 / #39787 / #40640）。**推论：分类只能靠命名前缀 + 平铺目录，不能靠目录树。**

### 1.3 官方提供的启停 / 作用域杠杆（精确到字段）

| 杠杆 | 配置位置 | 字段 / 值 | 效果 | 置信度 |
|---|---|---|---|---|
| **隐藏元数据（仍可手动调）** | SKILL.md frontmatter | `disable-model-invocation: true` | description **不进上下文**，模型不自动调，仍可 `/name` 触发 | high（CONFIRMED） |
| **隐藏菜单（模型仍可调）** | SKILL.md frontmatter | `user-invocable: false` | 从 `/` 菜单隐藏，description **仍常驻**，模型可自动调 | high |
| **运行时覆盖可见性** | `settings.json`（user/project/local） | `skillOverrides: { "x": "off" }` | `off`=完全隐藏（不进上下文）；`name-only`=只留名折叠描述；`user-invocable-only`；`on`=默认 | high |
| **权限级控制** | `settings.json` | `permissions.allow/deny: ["Skill(name)"]` | 前缀匹配 / 全禁 | high |
| **插件启停** | `/plugin` 或 settings | 插件级，**无法选择性启用插件内单个 skill** | medium |

注：plugin skills **不受 skillOverrides 影响**，只能 `/plugin` 管。`settings.json` 的 `additionalDirectories` **不会**加载其中的 skill（只有 `--add-dir` 会）。

## 2. "动态加载 / 路由"方案盘点 + 何时该上什么

### 2.1 方案对比（含为何多数是过度工程）

| 方案 | 原理 | 真降 always-on？ | 复杂度 | 适合规模 | 推荐给 AICAP？ |
|---|---|---|---|---|---|
| **三级渐进披露（已自带）** | 元数据常驻、正文按需 | 已是基线 | 零 | 始终 | ✅ 已在用，无需动作 |
| **作用域隔离（项目级 skill）** | 项目专属 skill 放该 repo `.claude/skills/` | ✅ **真降**（移出全局发现路径） | 低 | 任何规模 | ✅ **强烈推荐**——这就是"按类/按项目加载"的正解 |
| **`disable-model-invocation`** | 手动触发型 skill 的 description 移出常驻 | ✅ 真降 | 极低（加一行） | 任何 | ✅ 推荐用于 commit/sync/install/media 类 |
| **description 瘦身** | 实现细节下沉 body，frontmatter 只留 what+when | ✅ 小幅（~300-400 token） | 极低 | 任何 | ✅ 推荐（顺手做，本是写法规范） |
| **`skillOverrides: off/name-only`** | settings.json 折叠或隐藏描述 | ✅ 真降 | 低 | 任何 | 🔸 可选，作为作用域之外的细粒度补充 |
| **plugin 分包启停** | 一组 skill 打成插件，全局启停 | ⚠️ 启用时全组常驻；无项目级粒度 | 中 | 多组、跨项目复用 | ❌ 对 25 skill 过度；且 issue #9996/#13344/#29734 报告 enable/disable 不一定生效 |
| **路由 / 索引 skill** | 一个轻量 skill 常驻，触发后转交 | ❌ **不降**——顶层路由自身常驻；多一跳=新选错源 | 中 | 子项 20+ 且能移出发现路径 | ❌ YAGNI |
| **MCP 索引 server** | 技能目录暴露成 MCP resource，按需 load/unload | ✅ 真降（但需常驻 server + 索引基建） | 高 | 跨多 server、工具上百 | ❌ 严重过度 |
| **RAG-over-skills（向量检索）** | 嵌入 description，query 时检索 top-k 注入 | ✅ 真降（但引入"检索 miss = skill 根本不触发"新故障） | 高 | 工具破 50、schema 吃掉上下文显著比例 | ❌ 严重过度 |

**YAGNI 裁决（25-skill 规模）：** 路由 skill、MCP 索引、RAG-over-skills、plugin 分包——全部过度工程。它们的实证收益（如 RAG-MCP 把工具选择准确率 13.6%→43%、prompt token 砍 50%+）全部来自 **50+ 工具、单 schema 400-500 token、总量破 2 万 token** 的规模；你只在 ~3K token / 25 skill，差一个数量级。真到该上的那天，**优先复用 harness 自带的 Tool Search / deferred-tools 机制**（本会话就在用），别自建。

### 2.2 复杂度引入阈值表（到了再上，别提前）

| 触发条件 | 引入的技术 | 复杂度 | 为何此刻才值得 |
|---|---|---|---|
| **第 1 个 skill 起** | 作用域隔离 + 命名前缀 + 差异化描述 + 同域必跑 eval | 近乎零 | 地基，永远在；零基础设施却锁住未来所有档位的触发准确度 |
| **总库 > ~50 且类目聚集** | 按类选择性软链 / 分组启停 | 低（改 setup 脚本） | 复用已有 setup 机制，把全局集钉在 30–50 |
| **总库 > ~100 且要团队分发** | plugin 分包 + 按项目 enable/disable | 中 | **先实测 enable/disable 是否真降 always-on**（多 issue 报不生效） |
| **某类目子项 20+ 且仅本类用** | 把该类折成 index skill（路由） | 中 | 必须把子 skill 移出发现路径才真省 token，否则 index 是净增成本 |
| **全局可发现集逼近 ~150（≈上下文 10%）或总库 ~300+** | RAG / MCP 按需注入 | 高 | always-on 降到接近 0，但引入"检索 miss"新失败模式 |

## 3. 给当前 25 个 skill 的最小动作（今天就能做、收益最大）

1. **修 `short-drama` frontmatter**（加合法 `---` 包裹的 name/description）— 5 分钟，修真 bug。
2. **description 瘦身**（见下表，把实现细节下沉 body）— 写法规范 + 减触发噪声。
3. **作用域降级**（项目专属 skill 从全局移到对应 repo 的 `.claude/skills/`）— **减全局触发歧义，最大痛点。**
4. **手动触发型加 `disable-model-invocation`**（commit/sync/install/media 类）— 移出常驻预算 + 明确人介入边界（契合 ①）。

**description 瘦身清单**（目标：每个 ≤ ~350 字符，只留 what + when，触发关键词前置；实现细节进 body）：

| Skill | 现状 | 问题（实现细节误入 description） | 目标 |
|---|---|---|---|
| report-to-html | ~555–596 字符 | 含"参考 Anthropic 官方…避免 AI slop"整段设计哲学 | ~200 |
| project-health | ~509–536 | L0-L3 四层全列 + 长串触发词 | ~220 |
| req-discovery | ~499–539 | 三行触发词近义重复 + "Always trigger…"整段 | ~200 |
| survey | ~484–494 | "Phase 2 用 2 个 Claude agent…3 轮辩论"实现细节 | ~180 |
| video-hyperframes | ~40（偏瘦） | 触发词不足、可能欠触发 | 补 3–5 个触发词 |

> 合计可省 ~300-400 token。**这不是为省 token（< 2% 无所谓），而是顺手把写法纠成规范 + 减少触发噪声。**

---

# 第二部分 · 面向规模化的库建设蓝图（回答"建自己的库 + create/search/test/govern"）

## 4. 设计原则：地基先行，复杂度按阈值引入

四条承重判断（均经对抗验证）：

1. **渐进披露已替你做掉"正文动态加载"**：always-on 成本 = 所有"可发现"skill 的 name+description 之和，与正文长短无关。本仓库的发现路径就是 `setup-global-skills.sh` 软链到 `~/.claude/skills/`——**这笔账只在 skill 出现在该路径时才付。**
2. **拐点不在 50/100，触发准确度先死**：见 §0.3。你可能在 always-on 只占 4% 时就已经常被选错 skill。
3. **token 预算锚点：~100–130 token/skill**（官方基线 ~100，取保守上界 130 做估算更安全）。
4. **路由 / RAG / MCP 索引是有真实复杂度成本的重型基础设施**，在 ~100 skill 以下属于反模式。它们能省 token，却**救不了选错**（选错只能靠描述差异化 + eval 治）。

> **唯一现在就该做的"面向未来"投资**：从今天起给每个 skill 强制命名前缀 + 写差异化触发描述 + 把 eval 纳入新增 skill 的门禁。零额外基础设施，却把未来所有档位的触发准确度提前买断。

## 5. 可成长的分层架构（25 → 数百）

### 5.1 规模档位 → 加载/组织技术 → always-on 成本（按 130 token/skill 上界）

| skill 数 | always-on token | 占 200K | 占 1M | 该用的组织技术 |
|---|---|---|---|---|
| 25（现状） | ~3.25K | 1.6% | 0.3% | 作用域纪律 + 命名前缀（地基） |
| 50 | ~6.5K | 3.3% | 0.7% | + 按类选择性软链 / 分组启停 |
| 100 | ~13K | 6.5% | 1.3% | + plugin 分包（若要分发）；类内 index（若某类 20+） |
| 200 | ~26K | **13%（明显挤占）** | 2.6% | + 逼近触线时上 RAG/MCP 按需注入 |
| 300 | ~39K | **~20%（不可忽视）** | 3.9% | RAG/MCP 按需注入为主，作用域兜底 |

> **窗口决定 token 何时咬人**：本环境是 1M 窗口，所有档位 < 4%，token 维度几乎无压力——这把 token 拐点大幅后推，使**触发准确度成为唯一实际约束**。结论"地基优先、触发准确度先死"在 200K / 1M 两种窗口下都成立。

### 5.2 三层作用域模型（这就是"分层按类、做不同事调不同类"的落地）

- **L0 全局常驻**（软链进 `~/.claude/skills/`，对所有项目 always-on）：真正跨项目的工具箱——`skill-creator` / `install-skill` / `find-skills` / `survey` / `conventional-commit` / `diagnose` / `project-context` / `project-health` + 评审类。**作用域救不了这一层的膨胀，它的纪律靠描述差异化 + eval。**
- **L1 项目级作用域**（只装进某项目的 `.claude/skills/`，不进全局发现路径）：`ios-e2e-test` / `xcuitest-skill` / `feature-fullstack` / `webapp-testing` / `fedex-tracker`，以及 AICAP 自身专属的 `aicap-commit` / `sync-aicap` / `install-skill`。把全局集从 N 降到"当前项目真用得到的子集"，典型砍 50–70%（100 总库、单项目挂 30 → always-on 从 13K 降到 ~4K）。机制就是软链 / 目录归属决策，复杂度近乎零。
- **L2 按需可禁用**（`disable-model-invocation: true`）：有副作用、几乎只显式调用的——commit/sync/install 类，以及重而少用的 media 输出（`report-to-html` / `report-to-audio` / `video-hyperframes` / `canvas-design` / `short-drama`）。设了 flag 描述就不进上下文（模型不自动触发，仍可 `/name` 调）。**这是把 always-on 直接降下来的最便宜杠杆，且对触发准确度纯正向（候选少了）。**

> 随规模增长的迁移方向：**默认 L0 收紧、强绑定项目的下沉 L1、纯副作用的标 L2。** GitHub issue #62174 显示 Claude Code 的 per-project `enabledPlugins` 还没完全实现，所以本仓库走"软链选择性挂载"比依赖 plugin enable/disable 更可靠。
>
> ⚠️ **需你确认**（影响这套映射）：`feature-fullstack` / `ios-e2e-test` / `xcuitest-skill` / `req-discovery` 是否**真只服务单一 repo**？若你当通用模板跨多项目用，则保留 L0 全局 + 加 `disable-model-invocation`，而非降级项目级。这是据 description 推断，你的实际使用分布说了算。

### 5.3 分类骨架 + `categories.json` 单一清单驱动一切

> 前提澄清：**LLM 路由只看 `name+description`，不看目录/前缀**（官方：pure LLM reasoning，无 embedding/classifier）。所以分类的价值是**人类可发现性 + 作用域开关**，不是触发准确度。触发准确度靠"把关键词前置进 description 头 50 字符 + 写互斥句"。

Claude Code 会忽略未知 frontmatter key，所以可在每个 SKILL.md 加一个 metadata 块（`category` / `tags` / `scope` / `source` / `version`），再由脚本汇总成仓库根的 `categories.json`。**一份清单驱动三件事**：(1) `setup-global-skills.sh` 按 category/scope 过滤软链；(2) `aicap-commit` 生成 SKILLS.md / HTML 时按类目分组渲染；(3) eval 按类目分组跑回归。

建议 taxonomy（覆盖现有库）：

```
review        : plan-ceo-review / plan-eng-review / pre-land-review / debate-review / code-review / project-health
create-eval   : skill-creator
discover      : find-skills / install-skill / survey / deep-research
commit-govern : aicap-commit / sync-aicap / conventional-commit
research-report: report-to-html / report-to-audio / req-discovery / canvas-design
test-debug    : diagnose / verify / webapp-testing
build-ship    : feature-fullstack / ios-e2e-test / xcuitest-skill / fedex-tracker / short-drama / video-hyperframes
```

> ⚠️ **未验证**：`categories.json` 这套依赖"rulesync 跨目标分发时保留自定义 metadata block"。落地前需实测——若 rulesync 剥掉自定义字段，改用 sidecar 文件（`<skill>/meta.json`）旁挂，不进 frontmatter。

## 6. 全生命周期工具链：create / search / test / govern / distribute

**总评（经实测）**：五阶段里 **distribute / create 已 full**；search / test / govern 均 partial，短板**高度集中在"测试-治理这条轴还没通电"**，不是缺工具——**harness 在、wiring 不在。**

| 阶段 | 现有工具 | 覆盖度 | 缺口 | 最小补法（复用现有 rails） |
|---|---|---|---|---|
| **create** | skill-creator（authoring + 优化 + eval）+ install-skill / find-skills（外部获取） | **full** | — | 把 §7 authoring checklist 烤进 skill-creator 与 aicap-commit |
| **search** | find-skills / install-skill（外部市场）+ SKILLS.md（内部静态目录） | **partial** | 内部 catalog 无可查询索引；**新建前无查重** | 生成 `categories.json` + ripgrep over catalog；新建时跑描述重叠扫描 |
| **test** | skill-creator eval 脚本 + promptfoo | **partial** | **0/20 skill 有 trigger eval；promptfoo 只覆盖 1 个；CI job 被 `if: ${{ false }}` 硬关** | 写 `trigger_evals.json`（正例+邻近负例），打开被禁的 CI job 作第二道门 |
| **govern** | rulesync SSOT + ai:check 漂移门禁 + aicap-commit + sync-aicap | **partial** | frontmatter **无 version/deprecation**；无 library-health 度量；软链不 prune | 加 SemVer + tombstone 字段；`scripts/skill-health.py` 出 JSON；`setup:skills --prune` |
| **distribute** | rulesync 跨 4 工具 fan-out + setup:skills 软链 + sync-aicap + git remote | **full** | （非阻塞）无 per-skill 版本钉、无坏版本一键回滚 | 暂不补，等 govern 加了 version 字段后顺带 |

- **create**：skill-creator 已是完整 authoring 管线（draft → test-prompt → human review → improve loop → `run_loop.py` 描述质量优化（60/40 train/test、每 query×3 取触发率、按 test 分选 best_description 防过拟合）→ `package_skill.py` 打包），覆盖 frontmatter 规范 / 渐进披露 / 500 行上限。外部获取由 install-skill（GitHub API 浏览 anthropics/openai/vercel/cloudflare/自定义 repo）与 find-skills 补齐。**唯一要做的是把 §7 checklist 固化进去，让创建即合规。**
- **search**：两个发现工具都指向**外部市场**，内部 20 个 skill 只有手写 SKILLS.md。补法两面：(1) **内部检索**——`categories.json` + ripgrep over catalog（对 ~100 字符串建向量库是过度工程，**先 ripgrep，到 30–50 always-on + 真实误触发再考虑本地 sqlite-vec top-k**）；(2) **新建查重**——install-skill 与 skill-creator 写入前对 `categories.json` 跑描述重叠扫描（Jaccard > 0.3 或共享 3+ 触发词即 warn），**直接防住 test 阶段的路由撞车**。
- **test**：见 §8，最关键缺口。
- **govern**：一致性/漂移半边很硬（`ai-config-drift.yml` 在 PR + push main 上 `rulesync generate` 后 `git diff --exit-code`）；生命周期半边缺失——补 version/deprecation 字段 + library-health 产出器（§10 metric）。另注意 `setup-global-skills.sh` **只加软链不 prune**，删 skill 会留孤儿全局软链（在 `~/.claude` 不在 repo，逃过漂移门）——需要显式 unlink 或 `--prune`。
- **distribute**：链路完整且实测过（rulesync 把 20 个 skill 全量 fan-out 到 .claude/.cursor/.codex/.github 四处各 20；setup 脚本幂等、只建链接不覆盖真实目录、有 warn 分支）。**不动。**

## 7. 创建规范（authoring standard）

**Frontmatter 模板**：

```yaml
---
name: review-pre-land            # ≤64 字符，小写字母/数字/连字符；禁含 anthropic / claude
description: >                   # ≤1024 字符；第三人称；目标 < 350 字符
  Review a PR diff against base for SQL safety, LLM trust-boundary, and
  conditional side-effects before landing. 触发：pre-land review / 落地前审 /
  这个 PR 能合吗. 用本 skill 而非 code-review 当你要的是「落地门禁」而非「找 bug」.
category: review                 # 自定义 metadata（rulesync 保留性待验证，否则旁挂 sidecar）
scope: global                    # global | project:<name>
version: 1.0.0                   # SemVer：描述=触发契约
# disable-model-invocation: true # 仅副作用类（commit/sync/install）才加
---
```

**description 黄金三段式**（每条都写满，目标 < 350 字符）：① 动词陈述做什么；② 3–5 个触发关键词（从真实用户说法取）；③ **when-NOT 边界**——显式排除最易混淆的邻居（"用 X 不用 Y 当…"）。

**命名 / 命名空间**：原生命名空间 `plugin:skill` 的冒号前缀由 plugin 层给，**在 name 字段里非法**。所以**用连字符前缀做家族**（`review-` / `plan-` / `skill-` / `report-`）+ 在 description 里写**互斥句**——因为前缀本身对触发零帮助，区分全靠描述。只在"上百 skill 且要跨团队 plugin 分发"时才迁到冒号命名空间。

**bundled 资源**：当正文逼近 500 行、脚本会复用、大段 reference 仅子任务用、或操作是确定性的（该用脚本而非 prompt），就拆到 `scripts/` / `references/` / `assets/`；references 只下沉一层、>100 行加 ToC、明确标"Run vs See"。

**创建 checklist**（烤进 skill-creator 与 aicap-commit）：

- [ ] name 唯一、合规、动名词式
- [ ] description 第三人称、< 350 字符、三段式 + 互斥句
- [ ] 正文 < 500 行；确定性步骤已拆成 bundled 脚本
- [ ] references 只一层；路径用正斜杠；MCP 写 `Server:tool`
- [ ] `ai:generate` + 注册 SKILLS.md + `setup:skills` + `ai:check` 全绿
- [ ] **≥3 条 eval 跑出 CONFIRMED/REFUTED**（正例全中 + 邻近负例零误触发）
- [ ] **cursor-agent 跨模型复核描述**（⑤ 异构验证）

## 8. 测试与回归（别让新 skill 偷触发）

**现状（实测确认"harness 在、wiring 不在"）**：20 个 SSOT skill 里 **0 个有 should_trigger 邻近负例格式的 trigger eval**；只有 req-discovery 1 个 evals.json（无负例、未接 runner）；promptfooconfig.yaml 只含 conventional-commit 1 条（且是把 skillBody 当 system prompt 注入的 golden-trace，不是路由测试）；skill-creator 的 9 个 eval 脚本零 CI / 零 npm-script 调用；`ai-config-drift.yml` 里 prompt-eval job 被 `if: ${{ false }}` **硬关**。**触发路由正确性在 CI 上完全无保护。**

**每 skill 最小 trigger 规范**：在 `.rulesync/skills/<name>/trigger_evals.json` 放 `[{"query":"...","should_trigger":true|false}, ...]`：

- **≥5 正例**：必须触发它的真实说法，从自己的 description 触发词取。
- **≥3 邻近负例**：属于**最易混淆邻居**、必须**不**触发本 skill 的刁钻 query（"写个 fibonacci 函数"对 PDF skill 是无效负例）。**本仓库必写负例的邻居对**：`aicap-commit ↔ conventional-commit ↔ sync-aicap`；`plan-ceo-review ↔ plan-eng-review ↔ pre-land-review ↔ debate-review ↔ code-review ↔ project-health`；`survey ↔ deep-research ↔ find-skills ↔ install-skill`；`report-to-html ↔ report-to-audio ↔ canvas-design`；`diagnose ↔ project-health ↔ verify`。
- **两个指标**：trigger-recall = 命中正例/正例；false-trigger-rate = 误触发负例/负例。**Pass = recall 100% 且 false-trigger 0**，或放松到聚合 ≥90%。
- **方差**：触发是随机的，每条跑 k 次，pass-rate 落在 30–90% 不稳定带标为 "flaky trigger"——这是**描述要修**，不是 retry。

**库级 cross-skill 触发回归矩阵**：把所有 `trigger_evals.json` 的并集**对整个 skill 集（非孤立单 skill）**跑——这才暴露跨 skill 冲突。promptfoo 用 `skill-used` / `not-skill-used` 断言：每条正例 `assert: skill-used: <owner>`，**同一 query 同时是每个邻居的负例**。于是新增 skill B 一旦开始抢 skill A 的 query，A 的正例 recall 立刻回归——**"偷触发"从"感觉"变成具体的失败断言。**

**CI gate 怎么接（借 ai:check drift gate 模式）**：复制 `ai-config-drift.yml` 写法加 `skill-trigger-eval` job（`paths: ['.rulesync/skills/**']`、钉模型、`npx promptfoo eval --no-cache`、pass-rate < 90% 即 fail）。**那个 stub 已经写好（prompt-eval）、只是 `if: ${{ false }}`，翻开 flag + 喂 cases 即可。** 随机性防 flake：先 **PR report-only + 每周硬门**，把 flaky-case 压到 0 后再升级 PR 硬门。**每周再加一次跨模型回归**（Sonnet/Opus/GPT-5.5/Gemini）抓单模型漂移——⑤ 异构验证的 hook，做成 scheduled workflow 而非每 PR 成本。

> 阈值（业界 promptfoo / Anthropic / stack72.dev 收敛在 **90% 路由通过 + 0.90 描述质量**）是跨源收敛值，**未对本仓库高重叠的 review/commit/research 簇校准**，初跑可能要按 skill 调阈值。

## 9. "做不同的事调不同的类"的心智模型（澄清，避免误解）

你想要的不是运行时 OOP 式调度——Claude Code **没有**"运行期激活某一类、卸载另一类"的开关（那是 MCP tool-gating 的能力，不是 skill 的）。正确心智模型是**三个静态维度**：

- **维度 1 = 职能类（命名前缀 / 目录平铺）** → 给**人**做索引和 `/` 菜单分组。
- **维度 2 = 作用域（global / project）** → 决定**哪个项目里这个 skill 的元数据常驻**。这是"按类加载"的真实落点。
- **维度 3 = 触发型（auto / manual）** → `disable-model-invocation` 决定模型能否自动调、是否占常驻预算。

**"做不同的事调不同的类" = 在对的项目里（维度 2）、靠对的 description 触发词（维度 1 写准）让模型选对 skill（维度 3）。** 不是你写个 dispatcher，是把这三维配好，让框架的渐进披露 + 作用域 + LLM 路由替你做。

---

# 第三部分 · 落地

## 10. 规模化落地路线图（分阶段，按 skill 数触发）

| 阶段 | 触发条件 | 引入什么 | 一次性成本 | 收益 |
|---|---|---|---|---|
| **Phase 0** | 现在（~25） | ① 命名前缀 + 差异化描述纪律；② L0/L1/L2 作用域归类 + `disable-model-invocation` 标副作用类；③ `categories.json`（或 sidecar）接进 setup/SKILLS 生成；④ 给 4 个重叠簇的 ~12 个 skill 写 `trigger_evals.json`；⑤ 翻开被禁的 promptfoo CI job（先 report-only）；⑥ `scripts/skill-health.py` 出 baseline JSON；⑦ 瘦身 4 条胖描述、补 1 条瘦描述；⑧ 修 short-drama frontmatter | 低（几天，全是脚本 + 文本，零新基础设施） | 触发准确度提前锁住；always-on 立降；库质量从此可量化 |
| **Phase 1** | ~50 且类目聚集 | 按类选择性软链 / 分组启停（改 setup 脚本加分组开关）；全库 cross-skill 矩阵；frontmatter 加 version/deprecation；promptfoo 升级为 PR 硬门 | 低-中 | 全局集钉在 30–50（~4–6.5K）；偷触发有门挡住；退役有序 |
| **Phase 2** | ~100 且要团队分发 | plugin 分包 + 按项目 enable/disable（**先实测是否真降 always-on**）；某类目子项 20+ 则折成 index skill；`setup:skills --prune` 清孤儿软链；每周跨模型回归 | 中 | 跨项目 / 跨人分发；类内混淆收敛 |
| **Phase 3** | 全局集逼近 ~150（≈10%）或总库 ~300+ | RAG-over-skills 或把库做成 MCP server 按需注入（挂到 rulesync generate 流水线同步索引）；优先复用 harness 自带 Tool Search | 高 | always-on 降到接近 0；代价是引入"检索 miss"新失败模式，需召回监控 |

> **第一步刻意是修 bug + 瘦身 + 作用域 + 接 eval，不是建系统。** Phase 0 是全部价值的大头且零基础设施——它把未来每个档位的触发准确度提前买断。等到真有"全局可发现集逼近 ~150"或"总库 ~300+"的**可执行触发条件**再考虑动态加载基础设施。

**library-health 六个 metric**（做成单个 `scripts/skill-health.py` 出 JSON，对齐 project-health 的"可量化维度→探针→JSON"哲学）：

1. **EVAL 覆盖率** = 有 trigger_evals.json 的 skill / 总数 = 当前 **0/20 = 0%**（头号缺口）
2. **触发准确度**（recall & false-trigger）= 当前未测。目标 recall ≥ 90% / false-trigger ≤ 10% / flaky = 0
3. **元数据预算** = name+desc token 之和 = 实测 **~2.2–2.6K token**。fitness rule：任一描述 > 600 或 < 80 字符告警；单 PR 总预算涨 > X% 告警（像 bundle-size 那样按 PR 跟踪——**100 skill 时真正咬人的 metric**）
4. **邻居冲突数** = 矩阵里 false-trigger > 0 的 (A,B) 对 = 当前未测（"偷触发"计数器）
5. **重复度** = 描述高重叠的簇 = 手扫已见 review(6) / commit-sync(3) / research(4) 三簇
6. **漂移** = ai:check（generate + `git diff --exit-code`）= **唯一已全接好的 metric**；补一个"软链孤儿"检查

**生命周期状态机（create → deprecate，复用现有工具，绝不静默删除）**：

- **DRAFT** —(skill-creator 写 SKILL.md + trigger_evals.json)→ **EVAL**：跑到 recall 100% / false-trigger 0 且描述质量 ≥ 0.90
- **EVAL** —(ai:generate + setup:skills)→ **ACTIVE**：过单 skill eval **且** 库级矩阵无邻居回归 **且** 漂移门绿才进；aicap-commit 自动更新 SKILLS.md/HTML
- **ACTIVE** —(改描述 = 改触发契约)→ 重跑矩阵 + bump version：**PATCH** 仅正文 / **MINOR** 加宽触发（加性，邻居仍过）/ **MAJOR** 收窄或迁移触发（语义漂移，需重设邻居负例基线）
- **ACTIVE** —(被取代 / 低用 / 长期 flaky)→ **DEPRECATED**：frontmatter 标 `deprecated: true` + `superseded_by: <name>`，描述加 `(DEPRECATED — use X)` 前缀
- **DEPRECATED** —(宽限一个 release)→ **REMOVED/TOMBSTONE**：删 SSOT 目录 + ai:generate + `setup:skills --prune`；SKILLS.md 留 tombstone 行让旧链接可解析；版本控制 + 漂移门给回滚

## 11. 风险与不确定性（诚实标注 · ⑤ 本次未跑的探针）

**需你确认（影响 §5.2 映射）：**
- `feature-fullstack` / `ios-e2e-test` / `xcuitest-skill` / `req-discovery` 是否真只服务单一 repo？跨多项目用则保留 L0 + `disable-model-invocation`。
- 收编哪几个游离 skill 进 SSOT（当前 `feature-fullstack / fedex-tracker / ios-e2e-test / report-to-audio / short-drama` 是手动安装、游离在版本控制外，导致"按类启停"改动无法走管线）。纯一次性的（fedex-tracker）可不纳。

**实现层需本机实测（别只信文档）：**
- **rulesync 是否透传 `disable-model-invocation` / 自定义 `category` 字段到生成态**（generate 会剥掉一些字段）。落地前先 generate 一个看生成态 frontmatter；若被剥，`disable-model-invocation` 改用 settings.json 的 `skillOverrides`，`category` 改用 sidecar `meta.json`。
- **plugin enable/disable 是否真降 always-on**——多个 issue（#9996 / #13344 / #29734 / #62174）报告不生效。落地前挂一个 disable 的 plugin 看其 skill 描述是否仍进上下文。
- **issue #14882：某些 skill 启动时加载完整 body**（渐进披露实现不一致）。用 `/doctor` 或实测真实上下文占用核对。
- **available_skills 字符预算**（社区 issue #13099 实测 ~15,500–16,000 字符，溢出**整条 skill 被丢弃且无警告**，附 `Showing N of M`）。该数字非官方，按上下文比例缩放；你的库（25 skill × 均 ~280 字符 ≈ 7K 字符）目前安全，但 media/review 重的几个 + 增长会逼近——**直接 `/doctor` 看是否真截断，以本机为准。**
- **promptfoo 的 `skill-used` / `anthropic:claude-agent-sdk` provider 能否正确加载 SSOT skill 全集**——config 形状来自文档、未端到端跑过，建议先 spike 一个真矩阵确认。
- **90%/0.90 阈值对本仓库高重叠簇未校准**——初跑可能需 per-skill 调阈。

**依赖"截至 2026-06 的 CC 行为"、可能随版本变：**
- 官方**无** skill 级的 tool-search/deferred-skills（工具侧已对 MCP 工具 GA：v2.1.7 + `ENABLE_TOOL_SEARCH=auto`，超 10% 上下文自动转按需，省 ~85% token；skill 侧查无等价原生机制——§5 把 10% 当**类比触线**借用）。
- "按项目自动启停一组 skill"**无内置特性**——只能靠作用域 + skillOverrides 手工组合。
- **Cursor / Codex 是否同样尊重 `disable-model-invocation` 和项目级 `.claude/skills/` 作用域未逐一核实**（这些是 Claude Code 的字段）。rulesync 生成到各 target 时该字段在 Cursor/Codex 侧的等价行为需 per-target 验证。

**token 估算口径：** CJK ≈ 1 token/字、ASCII ≈ 0.27 token/字 的启发式，未跑真实 Anthropic tokenizer，真实值 ±10%；趋势比绝对值重要。精确值用 Anthropic count_tokens API 实测。

---

## 附：相关文件路径（均绝对）

- SSOT 源：`/Users/yongqian/Desktop/AICAP/.rulesync/skills/`（20 个）
- 生成态：`/Users/yongqian/Desktop/AICAP/.claude/skills/`（20 个，name+description 为 always-on 元数据）
- 全局发现：`/Users/yongqian/.claude/skills/`（25 个 = 20 软链 + 5 真实目录）
- 软链脚本（需改造支持白名单 / category 过滤 / `--prune`）：`/Users/yongqian/Desktop/AICAP/scripts/setup-global-skills.sh`（第 37 行起的全链循环）
- rulesync 配置：`/Users/yongqian/Desktop/AICAP/rulesync.jsonc`
- 漂移门禁（含被 `if: ${{ false }}` 硬关的 prompt-eval job，待翻开）：`.github/workflows/ai-config-drift.yml`
- promptfoo 配置（当前只覆盖 conventional-commit 1 条）：`/Users/yongqian/Desktop/AICAP/promptfoo/promptfooconfig.yaml`
- 待修 bug：`/Users/yongqian/.claude/skills/short-drama/SKILL.md`（首行 `# /short-drama` 非合法 frontmatter）

---

> 本报告可用 `/report-to-html` 转交互式网页、`/report-to-audio` 转音频概要（你库里已有这两个 skill）。
