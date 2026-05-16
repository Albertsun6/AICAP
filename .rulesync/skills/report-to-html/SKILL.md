---
name: report-to-html
description: |
  把一份长 Markdown 报告(调研/方案/设计文档,通常 200+ 行,含表格/流程图/引用链接)
  转成单文件交互式 HTML 网页:粘性目录、Mermaid 流程图、可折叠 Accordion、Pill 状态徽章、
  打印友好。零构建——Tailwind + Alpine + Mermaid 全 CDN,双击即开,邮件可发。

  Use when the user says:
  "把这个报告转成 HTML" / "做成交互式网页" / "可视化展示这份文档" / "/report-to-html xxx.md"
  "把这个 md 做个网页" / "生成一个能浏览的 HTML 版本" / "做成单页可交互的"

  适用:长调研报告、架构设计文档、方案对比、研究 brief。
  不适用:多文档站(那是 Docusaurus/Nextra 的活)、PPT 演示(用 pptx skill)、
  单页 landing page(直接写 HTML)、需要后端的应用。

  设计上参考 Anthropic 官方 web-artifacts-builder + frontend-design skill 的理念:
  避免 "AI slop"(居中紫渐变 / Inter 字体 / 大量 emoji),走稳重排版 + 信息密度优先。
targets: ["*"]
---

# /report-to-html — Markdown 长报告 → 交互式单页 HTML

## 工作流(5 步)

```
1. 读源文档 → 2. 结构分析 → 3. 生成 HTML → 4. 浏览器打开验证 → 5. 交付
```

### Step 1. Read 源 markdown

用 Read 工具完整读源文件。**禁止凭记忆/摘要去写**——长报告的细节(表格列、引用链接、pill 状态)必须从原文照搬。

### Step 2. 结构分析

提取:
- **章节列表** → 用于左侧粘性目录(通常 8-15 个 section)
- **流程/序列描述** → 转成 Mermaid `flowchart LR` 或 `flowchart TD`(数量限制:2-4 张图,只画核心流程,不要每个章节都塞图)
- **表格** → 保留所有列,关键行用色块/pill 强调
- **状态标记** → 例如"现行/已被取代/Sandbox/Graduated"等 → 转 pill
- **引用链接** → 所有外链必须保留 `target="_blank"`
- **可折叠内容** → 长附录/辩论历史/调研不足等次要信息用 `<details>`

### Step 3. 生成 HTML

参考模板:[references/template.html](references/template.html)(完整脚手架,含 Tailwind/Alpine/Mermaid 配置 + 中文字体栈 + 配色 + scroll-spy)。

输出文件命名:`<源文件名>.html`,放在源 .md 同目录。

#### 必备组件(均在 template 里)

| 组件 | 用途 | 实现 |
|---|---|---|
| 顶部 sticky bar | 标题 + 关键状态 pill + 打印按钮 | `<nav class="sticky top-0">` |
| 左侧粘性目录 | 滚动高亮当前节 | Alpine `x-data` + IntersectionObserver |
| Hero / 摘要卡 | 一句话执行摘要 + 关键指标 pills | `.section-card` + blockquote |
| 章节卡片 | 每个一级章节一张白底卡 | `.section-card` |
| 表格 | hover 高亮 + 关键行色块 | Tailwind `tbody tr:hover` |
| Mermaid 图 | 流程/序列 | `<div class="mermaid">` |
| Pills | 状态徽章 | `.pill-ok / .pill-warn / .pill-info / .pill-muted` |
| Accordion | 长附录折叠 | `<details><summary>` 原生 |
| Footer | 生成来源 + 日期 | `<footer>` |

### Step 4. 浏览器打开验证(必须)

```bash
open "<output>.html"
```

**质量检查清单**(在交付前自查):

- [ ] 滚动时目录高亮跟随
- [ ] 所有 Mermaid 图正常渲染(无报错/无空白)
- [ ] **Mermaid 节点显示真实文字**,不是 `Unsupported markdown: list` 占位框(见 Mermaid 节点 label 禁忌)
- [ ] 中文字体显示正常,行高舒适
- [ ] 所有外链可点击且 `target="_blank"`
- [ ] 表格在窄屏不溢出(关键表加 `overflow-x: auto` 包裹)
- [ ] 打印 / Print to PDF 时侧栏和导航隐藏
- [ ] Accordion 默认状态合理(一般默认收起)
- [ ] **无遗漏内容**:对照原 md 检查是否有章节漏掉

### Step 5. 交付

简要汇报:
- 输出路径(用 markdown 链接,VSCode 可点击)
- 实现的交互特性表(用户能直观看到价值)
- 后续可调整方向(配色/搜索框/深色模式/打印优化等)

---

## 设计原则(避免 AI slop)

参考 Anthropic [frontend-design skill](https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md)。

### 不要做

- ❌ 居中布局做主排版(单栏居中 = 调研报告的反模式)
- ❌ 紫色 / 蓝紫渐变背景
- ❌ Inter 字体配中文(中文用 PingFang SC / Noto Sans SC)
- ❌ 每个章节配 emoji 图标(降低专业感)
- ❌ 把每张表都做成卡片瀑布流(信息密度变差)
- ❌ 浅蓝/浅粉糖果色 pill 满屏飞

### 应该做

- ✅ 侧栏 + 主内容栏的经典文档布局
- ✅ 中性灰白底(#fafaf9 / #ffffff),强调色用一个(emerald 或 slate)
- ✅ 字体:中文优先 PingFang/Noto,英文/数字 system-ui,代码 JetBrains Mono
- ✅ 行高 1.7-1.8,段落宽度不超过 70ch
- ✅ Pill 只用 4 种(ok/warn/info/muted),不滥用
- ✅ 关键风险/警告用左边框块(`border-l-4`)单独突出,而非用整段背景色
- ✅ 信息密度优先:表格让信息一眼可比,不要每行都展开成卡片

---

## Mermaid 使用约束

- **图的数量**:整篇报告 2-4 张,只画核心流程。每章一张是过度。
- **中文标签**:用双引号包裹(避免未引号 CJK 报错)
- **节点 label 禁忌**(踩坑沉淀):**不要在 label 里写 `<br/>` 后跟数字/破折号/星号开头的字符串**——Mermaid 11.x 把 label 当 markdown 解析,`<br/>1. 构想` / `<br/>- item` / `<br/>* foo` 会被识别为 markdown list,渲染成大片黄色 `Unsupported markdown: list` 占位框,看起来像所有节点都坏了。安全做法:
  - ❌ `A["1. 构想<br/>Discovery"]`(数字 + 点 + `<br/>` → 触发)
  - ❌ `A["阶段1<br/>- 领域发现"]`(`<br/>` 后跟 `-` → 触发)
  - ✅ `A["1 构想 Discovery"]`(单行,空格分隔)
  - ✅ `A["阶段1 领域发现"]`(单行 CJK)
  - 如必须双行:把 `<br/>` 后第一个字符改成非 markdown-list 触发字符(中文/英文字母),或干脆改用 subgraph
- **主题**:用 `theme: "base"` + 自定义 themeVariables,字体匹配正文中文字体栈
- **方向**:横向流程用 `LR`,层级用 `TD`,序列用 `sequenceDiagram`
- **节点样式**:用 classDef 统一,不要每节点 inline 染色

---

## 与其他 skill 的关系

- **不要和 `survey` skill 混用调用栈** —— survey 出 markdown 报告,本 skill 是后续可视化层
- **不要替代 `pptx` skill** —— 要演示就用 pptx,要浏览阅读才用本 skill
- **如果需要复杂 React 组件** —— 升级到 Anthropic 官方 [web-artifacts-builder](https://github.com/anthropics/skills/blob/main/skills/web-artifacts-builder/SKILL.md)(需 Node/npm 环境)

---

## 验证过的真实案例

- 2026-05-15:`大型软件架构设计-完整报告.md`(350 行,11 节,82 引用,2 张 Mermaid 图) → 单文件 HTML(~750 行),无构建,浏览器双击即开。
- 2026-05-15:`3-5人AI团队做大型软件-完整流程.md`(232 行,12 节,1 张 Mermaid 8 阶段图)→ 41 KB HTML。**踩坑**:首版 Mermaid 节点用 `A["1. 构想<br/>Discovery"]` 想做双行 label,8 个节点全部渲染成黄色 `Unsupported markdown: list` 占位框。根因:Mermaid 11.x 把 label 当 markdown,`<br/>` 后的 `Discovery` 又被前一句的 `1.` 触发的 list 解析吞掉。修法:全改单行 `A["1 构想 Discovery"]`,流程图 + classDef 配色 + 虚线箭头一切正常。已沉淀到 §Mermaid 使用约束 §节点 label 禁忌。
