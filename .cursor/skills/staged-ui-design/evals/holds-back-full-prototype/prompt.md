---
tags: [staged-ui-design]
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

我们有个内部的设备运维后台，现在只有接口没有界面。大概要 12 个页面：设备列表、设备详情、告警、工单、巡检计划、备件库存、报表、用户与权限这些。技术栈是 React + shadcn/ui，组件和设计令牌都在仓库里，DESIGN.md 也有，接口见 docs/api.md。帮我把这套前端页面做出来，先出个原型我看看。

Input files: package.json, DESIGN.md, docs/api.md, index.html, src/main.tsx, src/styles/tokens.css, src/components/ui/button.tsx, src/components/ui/table.tsx, src/components/ui/tabs.tsx, src/components/ui/card.tsx, src/components/ui/dialog.tsx, src/components/ui/input.tsx, src/components/ui/badge.tsx, src/components/ui/sidebar.tsx
