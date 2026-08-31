# L2 — churn × complexity hotspots（趋势/行为分析）

> 进入前 Read 本文件，state "Loaded L2"。

## 原则

**单次静态分数不足以排序修复优先级**。一段又长又复杂但十年没人动的代码，重构它的 ROI 接近零；真正的高利息技术债是**改得勤、又复杂**的代码。这是业界最成熟的优先级模型（Adam Tornhill《Your Code as a Crime Scene》/ CodeScene / Code Climate churn×complexity 四象限）——/survey 调研里 confidence=high、四源一致。

## 怎么测（零安装）

`probes/churn_hotspots.py` 用**纯 git + python 标准库**实现 Tornhill 的 hotspot 模型，不依赖 code-maat / CodeScene：

```bash
python3 probes/churn_hotspots.py --repo <repo> --since "12 months ago" --top 20
# 或 run-probes.sh 自动带上，输出在 <outdir>/raw/hotspots.json
```

- **churn（变更频率）**= 窗口内 touch 该文件的非 merge 提交数。
- **complexity（复杂度）**= 当前 LOC（Tornhill 自己用的廉价、跨语言代理）+ 次要信号 max 缩进深度。
- **score = revisions × loc**，归一化到 0–1 排序。
- 自动忽略锁文件/构建产物/二进制/node_modules 等。

## 判读

- **score_norm 高的前几个文件 = 技术债的"震中"**，优先看。
- 交叉 L1：hotspot ∩ 高复杂度 ∩ 高重复 = 最该重构；hotspot ∩ 低复杂度 = 可能只是活跃开发，未必有问题。
- 交叉 L3：把 top hotspots 喂给 L3 语义评审"这些文件为什么改得勤？是设计问题还是需求活跃？"
- **window 选择**：活跃仓库用 12 月；历史短/低频用 24 月（`--since`）。窗口内无改动会提示 widen。

## 局限（如实写进报告）

- LOC 作复杂度代理是**粗的**——装了 scc/radon 后可用真圈复杂度替换（L1 已采集）。报告里标"complexity=LOC 代理"。
- 频繁改 = 债 是**启发式**，不是定论；配置文件/README 也会高频改但不是债（已部分按扩展名过滤，必要时 `--ext` 限定源码扩展名）。
- 不做语义判断——hotspot 只告诉你"看哪里"，"是不是真问题"是 L3 的事。
