# cursor-agent Invocation Helper

> /survey 在 Phase 2 (Agent X 异构搜索) 和 Phase 6 (异构终审 + Round 2/3 rebuttal) 调用 cursor-agent。所有调用细节集中在此，避免 phase 文件重复。

## 调用 4 硬点

1. **统一走脚本**：`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/survey/run-cursor-agent.sh <prompt-file> <output-file>`，不内联 bash（避免变量展开 / ARG_MAX / 临时文件清理出错）
2. **prompt 必须用 Write 工具生成**到 `/tmp/survey-prompt-<unix-ts>.txt`（Phase 2 Agent X）/ `/tmp/survey-r1-prompt-<unix-ts>.txt`（Phase 6 Round 1）/ `/tmp/survey-r2-prompt-<unix-ts>.txt`（Round 2）/ `/tmp/survey-r3-prompt-<unix-ts>.txt`（Round 3）；**禁用 heredoc / cat 内联**
3. **Bash 工具 timeout 参数固定 `300000`（300s）**——不是 macOS shell 里的 `timeout` 命令（macOS 默认没装；脚本探测 `gtimeout` 但不强制依赖，Bash 工具自己的 timeout 是唯一保护层）
4. **exit code → 降级路径完整映射**：

   | code | 含义 | 降级行为 |
   |---|---|---|
   | `0` | 成功 | Read 输出文件 `/tmp/survey-output-<ts>.md` 或 `/tmp/survey-r{1,2,3}-output-<ts>.md` |
   | `69` | not installed | + banner "cursor-agent not found" |
   | `124` | timeout >300s | + banner "cursor-agent timeout" |
   | `65` | call failed | + banner "cursor-agent error" |
   | `66` | empty output | + banner "cursor-agent returned empty" |

## 各 Phase 的降级路径

| 调用点 | 失败时 |
|---|---|
| Phase 2 Agent X | 退到 3 Claude（Agent X 换 Agent C，搜社区/经验类 source）+ 报告顶部 banner |
| Phase 6 Round 1 | 跳过整个 Phase 6（不进人类裁决）+ banner "HETEROGENEOUS REVIEW: SKIPPED" |
| Phase 6 Round 2 | 提前进入人类裁决（带 metadata banner 标注"AI 辩论未跑满 3 轮"） |
| Phase 6 Round 3 | 同 Round 2 |

## 调用模式（主 Claude 拼装步骤）

```text
1. Read 对应 prompt 模板（prompts/agent-x.txt / prompts/round1.txt / prompts/round2-rebuttal.txt）
2. 注入 context（Brief 全文 / Source Quality 评分 / Phase 2.5 Reflection / Phase 5.5 Citation Health / Round 1-N 历史矩阵）
3. Write 到 /tmp/survey-{prompt|r1|r2|r3}-prompt-<unix-ts>.txt
4. Bash: bash run-cursor-agent.sh <prompt-file> <output-file>，timeout=300000
5. Read 输出文件（如 exit 0）或 + banner（其他 exit code）
```

## 脚本职责边界

`run-cursor-agent.sh` 只做 cursor-agent CLI 调用 + 超时控制 + exit code 分类。**不做**：
- 不做 preflight 脱敏检查（涉敏内容用户手动 sanitize）
- 不做 prompt 文件清理（OS 自动清 /tmp）
- 不做输出后处理（主 Claude Read 后自行解析）

## 绝不

- **绝不**因 cursor-agent 失败让主流程失败——降级是设计目标，不是异常
- **绝不**用同一个 timestamp 给 Phase 2 + Phase 6 复用 prompt 文件——/tmp 命名冲突会导致互相覆盖
- **绝不**省略 Bash 工具的 timeout 参数——macOS 没有 `timeout` 命令时这是唯一保护层
