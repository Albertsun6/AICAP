# review

一个用于**pre-landing PR review（合并前 PR 审查）**的 Skill。

## 这个 Skill 是干什么的
它关注的是：**测试不一定能抓到，但上线后很容易炸的结构性问题。**

重点看：
- SQL / data safety（数据安全）
- race conditions（竞态）
- LLM trust boundary（LLM 输出信任边界）
- enum completeness（枚举完备性）
- conditional side effects（条件分支副作用）
- frontend diff 的轻量 design review

它是 landing 前最后一道偏结构化的守门。

## 什么时候用
适合这些场景：
- 分支差不多要合了，想做一轮结构性审查
- 你担心“测试绿了，但实现有埋雷”
- 你想自动修掉一部分机械问题，再决定剩余问题怎么处理

## 核心输出
通常会产出：
- 按严重级别分类的问题清单
- auto-fix 项与 ask 项
- Greptile 评论联动处理
- 前端 diff 的 lite design review

## 不适合的场景
它不适合：
- 还在方案阶段
- 还没开始写实现
- 需要完整用户流程 QA

## 相关 Skills
- `plan-eng-review`：实现前审查计划
- `qa`：实现后走真实流程
- `ship`：最终发版