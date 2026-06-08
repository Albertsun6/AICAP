# Rubric — 评估维度（7 关注点 + L0 治理）

> 跨项目复用单元。打分口径与项目无关，阈值见 `thresholds.md`。每维度 1–5 分或 `?`（数据不足）。

## 评分口径（统一）

| 分 | 含义 |
|---|---|
| 5 | 优秀：达标且有主动治理（CI 门禁/fitness function/ADR 在守） |
| 4 | 良好：达标，无明显风险 |
| 3 | 合格：基本可用，有改进点 |
| 2 | 偏弱：多处超阈值/明显异味，需要计划治理 |
| 1 | 差：系统性问题/红线 |
| ? | 数据不足（工具 skip / 非 git / 窗口空）——**不填空分** |

> 可量化维度的分**必须**引 `probes.json` 数字；软维度的分**必须**带 L3 异构 verdict。

## 维度

### D1 架构及框架合理性 [L1+L3]
- 量化信号：dependency-cruiser/import-linter 循环依赖数、越界 import 数、instability 分布。
- 语义信号（L3 异构）：分层是否清晰、依赖方向是否合理、框架用法有无反模式。
- 5 = 无循环依赖 + 有架构 fitness function 在 CI 守；1 = 多处循环依赖 + 分层形同虚设。

### D2 代码规范，代码精简 [L1]
- 量化：复杂度超阈值函数占比、Maintainability Index、lint 违规数。
- 5 = CC 普遍 <10、MI 高、lint 零违规且 CI 守；1 = 大量超复杂函数、无 lint。

### D3 目录结构合理性 [L1+L3]
- 量化：dependency-cruiser orphans（孤儿文件）数、跨界引用。
- 语义（L3 异构）：模块边界对应职责、无"杂物抽屉"、源码/测试/配置分明。
- 多为主观——**显式归 L3，不假装自动打分**。

### D4 冗余文件，无用文件 [L1]
- 量化：knip/vulture 的 unused files/exports/deps 数、jscpd 重复率。
- 5 = 近零死代码 + 重复 <阈值 + CI 禁新增；1 = 大量 unused + 高重复。
- 注：**只报告 + 标"疑似可删"，不擅自删**（CLAUDE.md ③）。

### D5 内容隔离，解耦 [L1+L2]
- 量化：no-circular 违规、instability、hotspot 是否为"上帝模块"。
- 语义（L3）：跨模块耦合是否过紧。
- 5 = 低耦合高内聚 + 无循环；1 = 紧耦合上帝模块。

### D6 技术架构合理性 [L2]
- 量化：churn×complexity hotspots 分布、MI 趋势。
- 5 = 债集中可控、震中少；1 = 多个高分 hotspot 且复杂度高。

### D7 历史评审的经验教训 [流程]
- 信号：有无 ADR/MADR、有无把过往评审固化成 lint/fitness rule、**复发率**（上次的问题这次还在不在）。
- 5 = 决策有 ADR + 教训已变规则在守；1 = 反复踩同一个坑、无留档。

### D0 仓库治理 / 供应链 [L0]（7 点之外，但属健康度）
- 量化：governance 探针的 license/security/ci/lockfile/secret/分支保护/bus factor。
- 5 = 基础件齐 + 分支保护 + 依赖治理 + 多作者；1 = 缺 license + committed secret + bus factor=1 + 无保护。
- **红线（committed secret / 高危依赖）→ 该维度直接 ≤2 并标 fail-closed**。

## 汇总呈现

**不出单一神奇总分**。按层画像：
```
L0 治理   ●●●○○   缺 license + 无分支保护
L1 门禁   ●●●●○   复杂度/重复达标，死代码工具未装(skip)
L2 债震中 ●●○○○   3 个高分 hotspot：a.py / b.ts / c.go
L3 软维度 ●●●○○   架构合理[异构 Concur]；目录有杂物抽屉[异构 Refine→已采纳]
```
