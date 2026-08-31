# Thresholds — 量化阈值表（冻结，可按项目调）

> 来自 /survey 调研的跨厂商收敛值（SonarQube/CodeScene/Codacy/Qodana/qodo/codeant 一致区间）。
> 这些是**默认起点**，不是教条；按项目阶段在评估开始时（Phase 0）声明用的是哪套。

## §complexity 复杂度
- 圈复杂度 / 认知复杂度：**< 10–15 / 函数**为绿；15–25 黄；>25 红。
- 工具：radon cc（Python）、scc（多语言）、eslint complexity（JS）。
- 判读：不是越低越好，是**异常高的离群函数**要重构。

## §MI 维护性指数
- Maintainability Index（0–100，VS 口径）：**≥ 20 可维护**；10–20 警戒；<10 难维护。
- 工具：radon mi（Python）、scc。

## §dead-code 死代码/冗余
- 目标：unused files/exports/deps **趋势归零**；CI **禁新增**（baseline 容忍存量）。
- 工具：knip（JS/TS）、vulture --min-confidence 80（Python）、deadcode（Go）。
- 注意 false positive：入口文件、动态 import、反射、框架约定保留——**报告标"疑似"，不擅删**。

## §duplication 重复
- 重复率：**≤ 3%** 优；3–10% 可接受；>10% 需治理。
- 工具：jscpd（150+ 语言）。

## §architecture 架构/耦合
- **循环依赖：目标 0**（no-circular 规则）。
- **孤儿文件：目标 0**（no-orphans，排除入口/类型声明）。
- Instability I=Ce/(Ca+Ce)（0 稳定 1 不稳定）：核心/被广泛依赖的模块应偏稳定（低 I）；叶子模块可不稳定。
- 工具：dependency-cruiser（JS/TS，`--metrics` 出 instability）、import-linter（Python contracts）、ArchUnit（Java）。
- **价值在写规则**：装了工具≠有 fitness function，要把"架构应该长什么样"写成断言进 CI。

## §coverage 覆盖率（若项目测）
- 核心路径 **≥ 80%**；新代码 diff coverage 更严。
- 变异测试分（如用）≥ 60–70%。

## §governance 治理（L0）
- license / SECURITY.md / CI / 锁文件 / .gitignore：**应全 true**。
- committed .env secret：**必须 false**（红线）。
- 分支保护：默认分支应 protected。
- bus factor（窗口内作者数）：1 = 风险，建议 ≥2 + CODEOWNERS。

## §lifecycle 生命周期调节（CodeScene 思路）
- **活跃开发期**：阈值从严（code health 目标 8–9/10），新债零容忍。
- **维护期**：阈值可放宽（目标 ~5/10），重点防回归而非追完美。
- **遗留接管**：先建 baseline 冻结存量，只 gate 新代码（学 Qodana baseline / SonarQube "new code" gate）。
- 在 Phase 0 声明本次用哪档。
