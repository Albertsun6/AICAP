# iOS 模拟器测试 Skills 候选清单

调研时间：2026-05-17  
用途：为 AICAP 选型通用 iOS 自动化测试 skill，以替代/补充现有 Seaidea 专属的 `ios-e2e-test`。

---

## 候选对比

| # | Skill | 框架 | 来源 | 许可 | 推荐场景 |
|---|---|---|---|---|---|
| 1 | `xcuitest-skill` | XCUITest (Swift 原生) | LambdaTest/agent-skills | MIT | **Swift/SwiftUI 项目首选** |
| 2 | `mobile-e2e` | Maestro (YAML) | RSSNext/Folo | — | 跨平台 / 快速写流程 |
| 3 | `ios-sim-navigation` | WebDriverAgent | wordpress-mobile/WordPress-iOS | — | AI 导航 / accessibility tree |
| 4 | `foxctl-mobile-ios` | Facebook IDB | joshka0/foxctl | — | 需要底层设备控制 |
| 5 | `eas-ios-simulator-builds` | EAS | majiayu000/claude-skill-registry | — | 仅 Expo/React Native |

---

## 各候选详情

### [1] xcuitest-skill ⭐ 已安装

- **来源**：`LambdaTest/agent-skills/xcuitest-skill/SKILL.md`
- **框架**：Apple 原生 XCUITest + XCTest，Swift / Objective-C
- **能力**：
  - Element 查询（by ID / label / predicate / index）
  - 手势（tap / swipe / pinch / rotate / long press）
  - 断言（exists / isHittable / waitForExistence）
  - 系统弹窗自动处理（权限 alert）
  - Page Object 模式模板
  - CLI 运行：`xcodebuild test -scheme … -destination 'platform=iOS Simulator,name=iPhone 16'`
  - 云端真机（LambdaTest / TestMu）
- **触发词**：XCUITest / XCTest / iOS UI test / Swift test / XCUIApplication
- **附带参考文件**：`reference/playbook.md`、`reference/advanced-patterns.md`
- **安装状态**：✅ 已安装到 AICAP SSOT

---

### [2] mobile-e2e

- **来源**：`RSSNext/Folo/.agents/skills/mobile-e2e/SKILL.md`
- **框架**：[Maestro](https://maestro.mobile.dev)，YAML 描述测试流
- **能力**：
  - iOS Simulator + Android Emulator 跨平台
  - YAML flow 文件驱动（无需写 Swift）
  - Auth 流（注册/登出/登录）等常见场景模板
- **适合**：需要快速写 E2E 流、不想写 Swift 代码的场景
- **安装状态**：❌ 未安装

---

### [3] ios-sim-navigation

- **来源**：`wordpress-mobile/WordPress-iOS/.claude/skills/ios-sim-navigation/SKILL.md`
- **框架**：WebDriverAgent (WDA)，Appium 生态
- **能力**：
  - Accessibility tree 优先（description 格式，非 JSON）
  - REST API 驱动模拟器交互
  - 元素检视、截图、UI 树 dump
  - 适合 AI agent 自主导航 UI
- **适合**：需要 AI 自己"读懂" UI 结构并操作的场景
- **安装状态**：❌ 未安装

---

### [4] foxctl-mobile-ios

- **来源**：`joshka0/foxctl/configs/skills/foxctl-mobile-ios/Skill.md`
- **框架**：Facebook IDB（iOS Development Bridge）
- **能力**：
  - 设备枚举 / app 安装 / 启动 / 终止
  - UI 交互（tap / swipe）+ 截图
  - 调试工具（日志、崩溃报告）
  - Expo 支持
- **适合**：需要最底层设备控制、或 IDB 已在工具链中
- **安装状态**：❌ 未安装

---

### [5] eas-ios-simulator-builds

- **来源**：`majiayu000/claude-skill-registry/skills/data/eas-ios-simulator-builds/SKILL.md`
- **框架**：EAS（Expo Application Services）
- **能力**：构建 Expo/React Native dev client → 装到模拟器运行
- **适合**：仅限 Expo / React Native 项目
- **安装状态**：❌ 未安装（专用性太强，不纳入通用 SSOT）

---

## 安装决策记录

| 时间 | 操作 | 理由 |
|---|---|---|
| 2026-05-17 | 安装 `xcuitest-skill` | Swift 原生、MIT 许可、模式库完整，适配大多数 iOS 项目 |
| 2026-05-17 | 暂缓 `mobile-e2e` | 需要先确认项目是否用 Maestro |
| 2026-05-17 | 暂缓 `ios-sim-navigation` | WDA 部署复杂，按需再评估 |
| 2026-05-17 | 暂缓 `foxctl-mobile-ios` | IDB 是底层工具，先用 xcuitest 覆盖主流场景 |
| 2026-05-17 | 跳过 `eas-ios-simulator-builds` | 专用性太强，非通用 |
