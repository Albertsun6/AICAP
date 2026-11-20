# Phase 5.5：Citation Health + Claim Support Check (#4)

> **原则**：直接对抗行业未解的 citation hallucination 问题（Perplexity 独立测出 37% 误引率；URL 真实 ≠ 内容支持声明）。两层 pass。

**触发**：Phase 5 报告写完 / Phase 6 终审前。

## Layer A：URL Health Check

工具：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/check-citations.sh`（详见下方脚本 spec）

## Layer B：Claim-Support Verification（抽样）

- 抽样 **30% 关键 claim**（最少 5 条；关键 claim = 综合报告 §推荐 + §方案对比 表格中带置信度 high 的）
- **分工**（2026-11-20 改：11-12 实跑主 agent 自己逐条 WebFetch 占了约 5 min 关键路径）：**取原文**交给**一个** Agent 工具子 agent（`model=haiku`），**判定**留给主 agent。Layer A 脚本（约 1 min）跑完后立刻发出，URL 按 Layer A 结果给（ok 用原址，dead 用 wayback 快照）
- **搜索路已给原文引句的 claim 少抓一轮**（2026-11-20 加）：抽样 claim 的证据若在搜索路的引句表里有引句（见 `02-research.md` §搜索预算与停止条件），可以直接对照引句判档。但引句可能是编的、也可能漏了限定条件，所以：
  - **决策关键 claim 一律回抓**：**30% 样本里**支撑 §推荐 的选择、方案排序、推荐前提或适用条件的 claim，不论有没有引句都按下面的常规流程抓原文判档（抽样比例照旧是 30%；这条只是不让样本里的关键 claim 走引句直判，门禁不比原来松）
  - **按路分层抽查**：样本里其余带引句的 claim，**每一路**各抽 1/3（每路最少 3 条，不足 3 条就全抽），交给子 agent 回抓原页核对
  - **「不符」的定义**：引句在原页找不到、被改写过、原页上下文不支持该 claim、漏了改变含义的限定条件、或原页取不到——任一都算
  - **一条不符，整路作废**：某路有一条不符，这一路所有引句都不可信，它支撑的抽样 claim 全部按常规流程重抓判档，§metadata 记 `引句核对: <路名> 不符 <N> 条，已整路重抓`。按路作废靠的是 Phase 2 建的来源账本（claim—路—URL—引句），合并去重时不许丢掉「来自哪一路」
  - 没有引句（或写「未读原文」）的 claim，照常走下面的流程
- 子 agent 对每条要抓的 claim：WebFetch 对应 URL，摘出与该 claim 相关的原文段落（带上下文，含限定条件如地区、版本、适用范围）；回抽查引句的，同时回答「引句是否逐字出现在页面上、上下文有没有改变含义的限定条件」；取不到就写明原因。**只摘不判**
- 主 agent 先核对返回条数等于发给它的条数（缺条按 `not-supported` 计），再对照摘录或引句逐条判三档：`supported` / `partial` / `not-supported`
- 改稿：要改的地方攒齐后一次改完，不逐条 Edit
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
**引句核对**: 用引句直判 <Q> 条 | 决策关键全抓 <D> 条 | 按路回抓抽查 <R> 条 | 不符 <F> 条（不符的路：<路名或"无">）
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
