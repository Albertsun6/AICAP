---
name: conventional-commit
description: "把已暂存/已完成的改动整理成一条规范的 Conventional Commits 提交信息时调用——用户说'写提交信息'/'commit 这个'/'生成 commit message'时"
targets: ["*"]
---

# Conventional Commit 生成

被调用时：

1. 先看实际改动（`git diff --staged`，无暂存则 `git diff` + `git status`），**基于真实 diff** 写，不臆测
2. 按 Conventional Commits 1.0 输出：

```
<type>(<scope>): <简洁祈使句，<=72 字符，不加句号>

<body：为什么这样改、影响范围、权衡。每行 <=100 字符；琐碎改动可省略>

<footer：BREAKING CHANGE: ... / Closes #123，可选>
```

- `type` ∈ `feat|fix|refactor|perf|docs|test|build|ci|chore`
- `scope` = 受影响的模块/包名（可选但推荐）
- 一个提交只做一件事；如果 diff 跨多个无关变更，**提示用户拆分**而不是硬塞成一条

3. 只输出建议的提交信息（代码块），**不要自动执行 `git commit`**，除非用户明确要求

约束：不夸大；fix 必须确实修了某个行为；BREAKING CHANGE 必须如实标注。
