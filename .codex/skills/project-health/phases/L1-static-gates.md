# L1 — 静态门禁（可执行探针）

> 进入前 Read 本文件 + `rubric/thresholds.md`，state "Loaded L1 + thresholds"。

## 原则

**可量化维度一律用工具出客观 JSON，LLM 不许目测打分**（用户 CLAUDE.md ⑤ 的可执行验证）。这层覆盖用户 7 关注点里的"代码规范精简、冗余/死代码、重复、（部分）解耦与架构"。

## 维度 → 工具（run-probes.sh 自动选，按技术栈）

| 维度 | JS/TS | Python | 通用/其他 | 阈值见 |
|---|---|---|---|---|
| 死代码/冗余文件 | **knip**（unused files/deps/exports） | **vulture** | deadcode(Go) | thresholds §dead-code |
| 复杂度 | （eslint complexity）| **radon** cc | **scc**（多语言 CC）、lizard | thresholds §complexity |
| 维护性指数 MI | — | **radon** mi | scc | thresholds §MI |
| 重复 | **jscpd** | jscpd | jscpd（150+ 语言） | thresholds §duplication |
| 架构/耦合 | **dependency-cruiser**（no-circular/no-orphans + instability） | **import-linter**（layered contracts） | ArchUnit(Java) | thresholds §architecture |
| 规范 | eslint | ruff | — | 项目自带 lint 配置 |

## 怎么跑

```bash
bash probes/run-probes.sh --repo <repo> --out <outdir> --npx --pipx
# --npx：用 npx 临时跑 knip/jscpd/dependency-cruiser（无需全局装）
# --pipx：用 pipx 临时跑 vulture/radon/import-linter
# 都不加：只有 PATH 上已装的工具会跑，其余 skip + 给安装指令
```

读 `<outdir>/probes.json`：每个 `probes[]` 有 `category` + `tool` + `ran` + headline 数字 + `raw` 指向完整输出文件（不要把几千行原始输出塞进 context——Anthropic isolated-context 原则；要细节再按 `raw` 路径 Read）。

## 判读（对照 thresholds.md）

- **死代码**：knip/vulture 报的 unused exports/files/deps —— 列 top N，区分"真死"与"框架约定保留"（如入口、动态 import）。
- **复杂度**：超阈值函数（CC>10–15）列出来；不是越低越好，是**异常高的**要重构。
- **重复**：jscpd 的 `duplication_pct` 对照阈值（≤3–10%）。
- **架构**：dependency-cruiser 默认扫只查循环依赖；**真正的价值在写 `.dependency-cruiser.js` 规则**（no-circular / no-orphans / 禁止跨层 import），把"架构应该长什么样"变成 CI 断言（fitness function）。import-linter 同理需 `.importlinter` contracts。

## 关键提醒

- **架构 fitness function 不是装了工具就有**——要写规则。报告里若发现循环依赖/越界 import，固化动作 = "新增一条 dependency-cruiser/import-linter 规则 + 进 CI"。
- **死代码要谨慎删**（用户 CLAUDE.md ③：发现 dead code 指出来、别擅自删）。本 skill 只**报告** + 标"疑似可删"，删除决定留给用户。
- 工具全 skip 的维度 → 报告显式标"未自动覆盖"+ 安装指令，并把该维度降级到 L3 让 AI 粗判（带"未经工具确认"caveat）。
