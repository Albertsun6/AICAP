# plan-eng-review

一个用于**工程计划审查（engineering plan review，工程落地前审查）**的 Skill。

## 这个 Skill 是干什么的
它会在编码前，把计划压成更可执行、更少翻车的版本。

重点看这些：
- architecture（架构）
- data flow（数据流）
- failure modes（失败路径）
- tests（测试覆盖）
- performance（性能风险）
- minimal diff（最小必要改动）

它像一个有经验的 engineering manager（工程经理）在开工前帮你挑雷。

## 什么时候用
适合这些场景：
- 方案已经有了，但你想知道工程上稳不稳
- 改动会跨多个文件、模块或系统
- 你想先做 scope challenge（范围挑战）再进入开发
- 你希望输出一个能被 `qa` / `qa-only` 继续消费的 test plan

## 核心输出
通常会产出：
- Step 0 scope challenge
- 架构与代码质量问题清单
- test diagram（测试图谱）
- failure modes（失败模式）
- 可被 QA 复用的 test plan artifact

## 不适合的场景
它不适合：
- 纯战略讨论
- 纯设计讨论
- 已经到了合并前，只需要做最终 diff 审查

## 相关 Skills
- `plan-ceo-review`：上游问题与范围重构
- `plan-design-review`：设计层补完
- `qa` / `qa-only`：实现后的验证

