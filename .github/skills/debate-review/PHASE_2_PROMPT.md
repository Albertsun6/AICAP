# PHASE_2_PROMPT — Reviewer Cross-Pollinate

> **用途**：Review Mechanism v2 phase 2 辩论阶段，让两位 reviewer 互相阅读对方 verdict 后写 react verdict。本文是给 reviewer 的 prompt 模板，由各项目自带的 phase 驱动脚本在调 cursor-agent / Agent 时拼入。
>
> **关联**：完整三层评审机制由各项目自身的评审机制文档定义 · [debate-review SKILL.md](SKILL.md)（phase 3 裁决）

---

## Reviewer prompt 模板

填入：
- `<artifact_files>` — phase 1 的 artifact 文件清单
- `<own_verdict>` — 你 phase 1 的 verdict.md 内容
- `<sibling_verdict>` — sibling reviewer 的 phase 1 verdict.md 内容
- `<reviewer_role>` — `harness-architecture-review` 或 `reviewer-cross`

```
你是 {reviewer_role}。当前是 Review Mechanism v2 phase 2 辩论阶段。

## 输入

### Artifact files (phase 1 已读)
<artifact_files>

### 你 phase 1 的 verdict
<own_verdict>

### Sibling reviewer 的 phase 1 verdict
<sibling_verdict>

## 任务

逐项对 sibling 的**每条 finding**（BLOCKER / MAJOR / MINOR / OQ 强意见）表态四选一：

- **agree**：sibling 这条 finding 站得住，无补充
- **disagree-with-evidence**：必须给具体反例 + sibling finding 的失误点（"sibling 说 X，但实际 Y，因为 Z"）
- **refine**：方向对但分寸过 / 不及；给具体改法（"应改成 X' 而不是 X，因为 Y"）
- **not-reviewed-with-reason**：罕见。写明为何不评（如 "属 reviewer-cross lens，不在 arch 4-dim 范围"）

## 硬约束（违反则 verdict 失效）

1. **至少 1 条** disagree-with-evidence 或 refine。**不允许全部 agree**——全 agree → escalate "phase 2 信号弱"。
2. 不读 author 的 4 档分类草案 / counter（保持 phase 2 纯 reviewer cross-pollinate）。
3. 不读其他对话历史 / transcript（fresh context = 不继承前一轮 turn 上下文）。
4. 允许撤回自己 phase 1 的 verdict（升级 / 降级 / 删除某条 finding），但**撤回必须给反例**：
   - 具体的 sibling 证据
   - 自己原 verdict 的失误点
   - 例："我撤回 M3，因为 sibling 在 §X 指出我误读了 Y。"
5. 不修改任何文件——只产 react verdict markdown 到 stdout。

## 输出格式

```markdown
# Phase 2 React Verdict — <artifact name>

**Reviewer**: {reviewer_role}
**Phase**: 2 (debate / cross-pollinate)
**Model**: <model>
**Date**: <YYYY-MM-DD HH:MM>
**Read sibling**: <sibling verdict file path>

---

## 对 sibling finding 的逐项表态

### sibling B1 [BLOCKER] <title>
**Stance**: agree / disagree-with-evidence / refine / not-reviewed-with-reason
**Evidence / Refinement**: <≤ 80 字>

### sibling M1 [MAJOR] <title>
**Stance**: ...
**Evidence / Refinement**: ...

(对 sibling 每条 finding 一项)

---

## Self-revision (可选，但撤回必须给反例)

- **Withdraw / Upgrade / Refine my own phase 1 finding**：
  - 例：撤回 M3，因为 sibling §X 指出 ...
  - 例：升级 m2 to MAJOR，因为 ...

---

## New findings (可选，phase 2 才浮出的)

读 sibling 的 verdict 后联想到的、phase 1 双盲都没提的新 finding。

### N1 [BLOCKER / MAJOR / MINOR] <title>
**Where**: ...
**Issue**: ...
**Suggested fix**: ...

---

## Stance distribution

- agree: N
- disagree-with-evidence: M
- refine: K
- not-reviewed-with-reason: J
- self-revisions: P
- new-findings: Q

(M + K ≥ 1 才合法 phase 2 verdict)
```

## 反例

不要这样：
- ❌ 对 sibling 每条都 "agree, 无补充"（违反硬约束 1）
- ❌ 撤回自己 finding 但不给反例（"我看了 sibling 觉得自己错了" 不算反例）
- ❌ 引用 author 的 transcript / 思考流（违反硬约束 2）
- ❌ 跳过某条 finding 不表态（必须四选一覆盖 sibling 所有 finding）
