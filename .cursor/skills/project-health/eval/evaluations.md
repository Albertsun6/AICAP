# Evaluations — eval-first（先写验证，再信 skill）

> 官方 best practice："Create evaluations BEFORE writing extensive documentation"。对应 CLAUDE.md ④——只有可执行验证才约束 agent。
> 这些是 /project-health 自己的验收场景：跑这个 skill 应当稳定通过下列断言。每次改 skill 后回归。

## 如何用

对一个**已知答案**的样本仓库跑本 skill，核对 `expected_behavior`。样本可用 AICAP 本仓库 / AISEP6-6 / 任一公开仓库。断言是行为级（不是逐字输出）。

---

## E1 — 零安装也出价值（优雅降级）
- **setup**：在一台**没装任何探针工具**的机器上，对一个 git 仓库跑 `probes/run-probes.sh`。
- **expected_behavior**：
  1. 不报错退出（exit 0），不因缺工具崩。
  2. `hotspots` 探针照常产出 top 文件（纯 git+python）。
  3. `governance` 探针照常产出 license/secret/分支保护/bus factor 等实测。
  4. 缺失的工具进 `skipped[]`，每条带可照抄的安装指令。
  5. 报告显式标"未自动覆盖 + 安装指令"，**不把 skip 当通过**。
- **已验证**：2026-06 在本机（无 knip/vulture/radon/scc/...）对 AISEP6-6 + AICAP 跑通，ran=2 skip=5/4。

## E2 — hotspot 排序正确
- **setup**：对一个有提交历史的仓库跑 `churn_hotspots.py`。
- **expected_behavior**：
  1. score = revisions × loc，降序；score_norm ∈ [0,1]。
  2. 锁文件/二进制/node_modules/dist 不出现在 hotspots。
  3. 已删除文件不计当前复杂度（只算磁盘上现存文件）。
  4. 非 git 仓库 → `{ok:false, error:"not a git work tree"}`，不抛异常。
- **已验证**：AISEP6-6 正确把高频改+大文件的 quality/gates.py 排第一。

## E3 — 红线 fail-closed
- **setup**：仓库里 `git add` 了一个 `.env`（非 .env.example）。
- **expected_behavior**：
  1. governance 探针 `committed_env_secret_risk = true`。
  2. 报告把 D0 该项标红、要求人工确认、给固化动作（gitleaks + 轮换 + 清历史）。
  3. **不**静默放行（invariant 5）。

## E4 — 软维度必经异构
- **setup**：跑完整流程到 L3。
- **expected_behavior**：
  1. 架构/目录/解耦/历史 4 个软维度的每条结论都带 file:line 证据（无证据结论不接受）。
  2. 走了 cursor-agent 异构终审；主 agent 对每条意见有 accept/partial/defer/refute 表态。
  3. cursor-agent 不可用时：报告顶部出现 banner，软维度标高风险，**主流程不失败**。
  4. 3 轮辩论后仍分歧 → 触发 AskUserQuestion 人类裁决。

## E5 — 固化闭环
- **setup**：发现一条循环依赖 / 一个架构决策。
- **expected_behavior**：
  1. 循环依赖 → 固化动作 = "写 dependency-cruiser/import-linter 规则进 CI"，标"可机器检查"。
  2. 架构决策 → 固化动作 = "写 ADR"，标"仅留档"。
  3. 报告 §固化清单非空（否则视为评估未完成）。

## E6 — 不越界（边界）
- **setup**：用户给一个 PR diff 说"评审这个"。
- **expected_behavior**：本 skill 不接管——提示用 `/code-review` / `pre-land-review`；/project-health 评的是整仓库。

## E7 — 覆盖完整性（7 关注点全有落点）
- **expected_behavior**：报告维度表覆盖用户原始 7 关注点（架构/规范精简/目录/冗余/解耦/技术架构/历史教训）+ D0 治理；任一维度要么有分要么标 `?`+原因，无遗漏。

---

## 回归检查清单（改 skill 后跑）
- [ ] E1 零安装跑通（run-probes.sh 不崩 + hotspots/governance 出数）
- [ ] E2 churn_hotspots.py 在 git / 非 git 两种输入都正确
- [ ] probes.json 是合法 JSON（`jq . probes.json` 不报错）
- [ ] 所有 Read gate 文件存在（phases/* rubric/* prompts/*）
- [ ] cursor-agent 不可用路径有 banner、不 crash
