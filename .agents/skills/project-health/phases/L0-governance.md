# L0 — 仓库治理 / 供应链健康

> 进入前 Read 本文件，state "Loaded L0"。

## 原则

repo health **不只是代码**。一个代码写得漂亮但没 license、依赖一堆已知漏洞、分支无保护、只有一个人懂（bus factor=1）的仓库，不是健康的仓库。这层最容易被"只看代码质量"的评估漏掉——本 skill 的 /survey 调研里，这一层正是异构终审（GPT-5.5）补回来的（OpenSSF Scorecard）。

## 怎么测

`probes/run-probes.sh` 的 `governance` 探针**零安装**就跑（纯 shell + git），产出：

| 检查 | 含义 | 不健康信号 |
|---|---|---|
| `license` | 有无 LICENSE/COPYING | false = 合规风险，外部无法安全使用 |
| `security_policy` | 有无 SECURITY.md | false = 无漏洞上报渠道（OpenSSF Scorecard 检查项） |
| `ci_present` | 有无 CI 配置 | false = 无自动门禁 |
| `dependency_lockfile` | 有无**真锁文件**（package-lock/pnpm/poetry/uv/Cargo.lock/go.sum…） | false = 构建不可复现 |
| `dependency_manifest` | 有无依赖清单（package.json/pyproject/requirements） | 与 lockfile 分开：requirements.txt 不算锁文件 |
| `committed_secret_risk` | 提交了 .env **或** secret 内容扫描命中 | **true = 红线**，`requires_human_confirm`，立即人工确认 |
| `secret_hits` | 命中的规则名 + **文件路径（不含 secret 值）** | 非空=有疑似硬编码凭据 |
| `debt_markers` | TODO/FIXME/HACK/XXX 数量 | 趋势看，绝对值因仓库而异 |
| `active_authors` | 窗口内不同作者数 | 1 = bus factor 风险（CHAOSS Contributor Absence Factor） |
| `branch_protection` | **GH 默认分支**是否受保护（gh repo view 取默认分支，非当前 HEAD） | unprotected = 可直推、可强推 |
| `codeowners`/`contributing`/`readme`/`gitignore` | 协作与可维护性基础件 | 缺失=协作摩擦 |

另有 `dependency_vulns` 探针：JS 有 package-lock 时跑 `npm audit`（零额外安装）；Python 有 `pip-audit` 则跑；都标 `requires_human_confirm`。其余给安装指令（osv-scanner 覆盖全语言）。

**secret 扫描的安全约束（重要）**：扫描只输出**规则名 + 文件路径**，**绝不把命中的 secret 内容写进任何文件**（否则评估本身就成了外泄渠道——这正是异构评审抓出的点）。规则：AWS AKIA、GitHub token、Slack token、PRIVATE KEY 块、`key/secret/token/password=「≥12 字符」` 的赋值；排除 .lock/.example/.sample/.template。

**升级路径（可选，更全）**：装 [OpenSSF Scorecard](https://scorecard.dev/) 自动产出分支保护、依赖更新工具、签名提交、SAST、token 权限等 18 项；GitHub Dependency Review 查依赖 age/license/漏洞；gitleaks/trufflehog 做更强 secret 扫描。探针在 skip 列表给安装指令。

## 判读

- **红线（fail-closed，`requires_human_confirm=true`）**：`committed_secret_risk=true`、`dependency_vulns.total>0`。标红、要求人工确认，不静默放行（invariant 5）。
- **黄线**：无 license / 无 SECURITY.md / 无分支保护 / bus factor=1 / 只有 manifest 没 lockfile → 列入报告 §建议，给固化动作。
- **绿线**：基础件齐 + CI + 真锁文件 + 多作者 + 分支保护 + 零 secret 命中。

## 固化（写进 Phase 99 的"教训→规则"）

- 缺 license/SECURITY → 直接补文件（一次性）。
- bus factor=1 → 建议 CODEOWNERS + 知识分享，不是代码问题但是健康问题。
- committed secret → 加 pre-commit secret 扫描（gitleaks）+ 轮换密钥 + 从历史清除。
- 依赖治理 → 开 Dependabot/Renovate + Dependency Review gate。
