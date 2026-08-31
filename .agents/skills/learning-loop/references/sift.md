# sift.md — 自抓单 URL 前的来源核查门(Phase 1 用)

> **只在**"单个已知 URL / 小范围 fetch、且本 skill 自己抓"时用。话题宽泛/不熟/需多源 → 回 Phase 1 委派 `deep-research` / `survey`,别在这门里硬抓。
> 蒸馏任何自抓内容**之前**必须先过这门。

## SIFT 四步(Caulfield 2019, "SIFT — The Four Moves", hapgood.us)
1. **S — Stop**:动手前停一下。你认识这个来源吗?信誉如何?别被页面卖相带着走。
2. **I — Investigate the source**:**横向**查这个来源是谁(下条),花 30 秒搞清它的立场/资质再决定信不信。
3. **F — Find better/other coverage**:对承重的事实,找**更好或其他**的报道来三角验证;优先一手/权威。
4. **T — Trace claims to the original**:把引文/数据/图**追到原始出处**,别信二手转述。

## 横向阅读(Wineburg & McGrew 2019, Teachers College Record 121(11))
- 实证:核查员 100% 判对来源可信度,PhD 历史学家只有 50%——差别就在**横向**(开新标签查这个来源)而非纵向(在原页面上下读)。
- **规则**:信一个来源/结论之前,**至少发起 1 次"关于这个来源/结论"的独立检索**。绝不只凭页面自身的线索(它自我介绍说自己权威不算数)。

## 落到笔记
- 把摄入判定写进笔记 frontmatter 的 `sift:` 字段:`trusted`(查过,可信)/ `investigated`(查过,有保留)/ `better-coverage-found`(找到了更好的来源,已换)。
- 每条承重事实把出处**追到原始**并写进 `## Sources`;单一来源标 `confidence: low`。
- 横向查下来站不住的来源 → **不蒸馏**,或只作为"有争议"标注。
