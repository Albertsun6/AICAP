---
description: 对外部 AI 的评审反馈做结构化辩论裁决：接受 / 部分接受 / 反驳，并落到原文件
targets: ["*"]
---

Run the `debate-review` skill workflow.

Use when I paste a code review / architecture critique / design feedback from another AI (Cursor, GPT, Gemini, etc.) and want structured arbitration rather than blindly accepting all suggestions.

Workflow:
1. Read the pasted review verdicts (phase 1 + phase 2 react verdicts if available)
2. For each verdict: classify as accept / partial-accept / reject with explicit reasoning
3. Apply accepted fixes to the target file(s)
4. Output a decision matrix summarizing what changed and why

Hard rules:
- Do not blindly accept all suggestions — push back where the reviewer is wrong
- Each rejection must include a counter-argument, not just "disagree"
- Apply fixes inline; do not create separate patch files
- If the original file is unknown, ask before guessing
