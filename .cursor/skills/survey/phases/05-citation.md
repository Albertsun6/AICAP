# Phase 5.5：Citation Health + Claim Support Check (#4)

> **原则**：直接对抗行业未解的 citation hallucination 问题（Perplexity 独立测出 37% 误引率；URL 真实 ≠ 内容支持声明）。两层 pass。

**触发**：Phase 5 报告写完 / Phase 6 终审前。

## Layer A：URL Health Check

工具：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/check-citations.sh`（详见下方脚本 spec）

## Layer B：Claim-Support Verification（抽样）

- 抽样 **30% 关键 claim**（最少 5 条；关键 claim = 综合报告 §推荐 + §方案对比 表格中带置信度 high 的）
- 对每条 claim：
  1. 取它引用的 URL（优先 ok，其次 wayback）
  2. WebFetch 该 URL 内容
  3. 由主 agent（或 LLM call）判定页面内容是否实际支持声明
  4. 三档评分：`supported` / `partial` / `not-supported`
- 输出 JSON：每条抽样 claim + 评分 + 引用页面摘录

## 失败阈值

- **Layer A**：dead URL 占比 > 10% → 失败
- **Layer B**：not-supported 占比 > 20% → 失败
- 任一失败 → **拒绝 finalize，回 Phase 2 重搜**（限 1 次重试；二次失败时报告含警告标识，强制进 Phase 6 + 标 banner）

## 报告写入 §调研 metadata 子段 `Phase 5.5 Citation Health`

```markdown
#### Phase 5.5 Citation Health

**Layer A**: <N> URLs total | <M> ok (<M%>) | <K> wayback-only (<K%>) | <J> dead (<J%>)
**Layer B**: <S> claims sampled | <Y> supported (<Y%>) | <Z> partial (<Z%>) | <W> not-supported (<W%>)
**Verdict**: PASS / FAIL（含失败原因）

详细列表（如失败）：
- dead: <URL list>
- not-supported: <claim + URL list>
```

## `check-citations.sh` 脚本 spec

位置：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/check-citations.sh`
输入：`<report-path>` 报告 markdown 文件
输出：`<report-path>.citation-health.json`（同目录）+ stdout 简报

主要逻辑：
1. 用 `grep -oE 'https?://[^ )]+'` 抽 URL
2. dedup
3. 对每个 URL：`curl -I -o /dev/null -w "%{http_code}" --max-time 10 -L`
4. 非 200/3xx 时调 `https://archive.org/wayback/available?url=<url>` 取最近快照
5. 汇总 JSON
6. 退出码：0 PASS / 65 FAIL Layer A / 66 FAIL Layer B（Layer B 由主 agent 后续触发，脚本只做 Layer A）

依赖：bash + jq + curl。

Quality 评分见 `../references/source-quality.md`。
