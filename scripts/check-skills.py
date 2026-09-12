#!/usr/bin/env python3
"""skill 一致性 / 断链门禁。

为什么不是 grep：正文里出现另一个 skill 的名字，绝大多数是假阳性——
"Correctly diagnose peacetime vs wartime" 命中的是英文单词而非 `diagnose` skill，
示例输出里的 skill 清单也会被当成调用。所以调用图必须**显式声明**：

    invokes:    本 skill 运行时会让对方真正跑起来（模型硬调用）
    recommends: 本 skill 只是指向对方（给人的路由 / 复用其规范），不触发它

这两个字段只存在于 .rulesync/ SSOT 源；rulesync 8.18.0 会把未知 frontmatter
字段从产物里剥掉，所以它们不进任何工具的上下文，也不影响 drift gate。

显式声明管的是「会不会跑」。名字还在不在是另一回事，由两条规则分别兜住：
    S10 正文 / description 里以 `/kebab-case` 点名的 skill 必须存在（字面，静态可判）
    G6  本机 skillOverrides 把被引用的 skill 关到模型看不见（S6 只读 frontmatter，
        读不到 settings，所以「skill 存在但已失效」这一类此前没人管）

分两层跑：
  SSOT 层  —— 只看仓库内容，CI 可跑，违规一律 ERROR
  全局层  —— 需要本机 ~/.claude/，CI 上自动跳过；断链是 ERROR，收录差异是 WARN
             （队友机器上本地 skill 天然不同，不该因此变红）

用法：python3 scripts/check-skills.py [--ssot-only] [--strict-global]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SSOT_DIR = REPO / ".rulesync" / "skills"
SKILLS_MD = REPO / "SKILLS.md"
GLOBAL_HOME = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))

# description 长度有两个上限，取严者：
#   1024 —— Agent Skills 开放标准 spec（Anthropic 官方 skill-creator 的
#           scripts/quick_validate.py 就按这个校验）
#   1536 —— Claude Code 在 skill listing 里对 description + when_to_use 的截断阈值
# 满足 1024 就同时满足两者。警戒线设在 78%——等超了才报是事后诸葛，
# 那时信息已经在静默丢失了。
DESC_LIMIT = 1024
DESC_WARN = 800

errors: list[str] = []
warnings: list[str] = []


def repo_checkouts() -> list[Path]:
    """本仓库的所有 checkout 根（主 checkout + 各 worktree）。

    在 worktree 里跑门禁时，~/.claude/skills 的 symlink 指向的是主 checkout，
    不是当前工作目录——只跟 REPO 比会把 24 条全判成假阳性。
    """
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), "worktree", "list", "--porcelain"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return [REPO]
    roots = [Path(ln[len("worktree "):]).resolve()
             for ln in out.splitlines() if ln.startswith("worktree ")]
    return roots or [REPO]


def err(rule: str, msg: str) -> None:
    errors.append(f"[{rule}] {msg}")


def warn(rule: str, msg: str) -> None:
    warnings.append(f"[{rule}] {msg}")


# ---------------------------------------------------------------- frontmatter

def _block_scalar(rest: str) -> str:
    """取一个 YAML 块标量（`|` / `>-`）的内容。

    只收**连续的**缩进行,遇到第一个非缩进的非空行就停——那已经是下一个键了。
    曾经的写法是 `[ln for ln in rest.splitlines() if ln.startswith((" ", "\\t"))]`,
    它把 description 之后**所有**缩进行都吸进来,于是 `allowed-tools:` 的 YAML
    列表项(`- Read`)、`claudecode:` 块的内容都混进了 description。
    实测踩中 4 个 skill:plan-ceo-review +56 字符、plan-eng-review +66、
    pre-land-review +75、xcuitest-skill +63。空行在块内合法(learning-loop 的
    description 靠空行分段),所以空行不终止,但也不能让它把块外的东西带进来。
    """
    out: list[str] = []
    for ln in rest.splitlines():
        if ln.startswith((" ", "\t")):
            out.append(ln)
        elif not ln.strip():
            out.append(ln)  # 块内空行:先收着,末尾统一 strip
        else:
            break           # 非缩进的非空行 = 下一个键,块到此为止
    return "\n".join(out).strip()


def parse_frontmatter(path: Path) -> dict:
    """够用就好的解析器：只认本门禁需要的几个键，不引 PyYAML。"""
    text = path.read_text(encoding="utf-8", errors="replace")
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---\n", 3)
    if end == -1:
        return {}
    fm = text[4:end]
    out: dict = {"_body": text[end + 5 :]}

    m = re.search(r"^name:\s*(.+?)\s*$", fm, re.M)
    if m:
        out["name"] = m.group(1).strip("\"'")

    # scope: project —— 只在本仓库内有意义，不该进全局发现面
    m = re.search(r"^scope:\s*(\S+)\s*$", fm, re.M)
    out["scope"] = m.group(1).strip("\"'") if m else "global"

    # description 可能是行内、>- 折叠或 | 字面块，只判断"有没有实质内容"
    m = re.search(r"^description:\s*(.*)$", fm, re.M)
    if m:
        inline = m.group(1).strip()
        if inline and inline not in (">", ">-", "|", "|-"):
            out["description"] = inline
        else:
            out["description"] = _block_scalar(fm[m.end() :])

    for key in ("invokes", "recommends"):
        m = re.search(rf"^{key}:\s*(\[.*\])\s*$", fm, re.M)
        if m:
            try:
                out[key] = json.loads(m.group(1))
            except json.JSONDecodeError:
                err("S0", f"{path}: `{key}` 不是合法的 JSON 数组流式写法")
                out[key] = []

    # claudecode: 块里的 disable-model-invocation（缩进两格）
    out["user_invoked"] = bool(
        re.search(r"^claudecode:\s*$.*?^\s+disable-model-invocation:\s*true",
                  fm, re.M | re.S)
    )
    return out


# ---------------------------------------------------------------- SKILLS.md

# 指向"某台机器上某个 checkout"的路径。~/.claude 是标准位置，不在此列。
MACHINE_PATH_RE = re.compile(r"(?:/Users/[\w.-]+|~/Desktop)(?!/\.claude\b)/[^\s`'\"）)]*")

# 正文 / description 里以 `/kebab-case` 点名的 skill。只认这一种**无歧义**写法：
#   · 必须带连字符 —— 单词型 `/tmp`、`/skills`、`/qa` 绝大多数是路径或内置命令
#   · 前面不能是 词字符 . / ~ $ } 引号 - —— 排除路径段、shell 展开、`A/B`、`读/写`
#   · 后面不能是 词字符 / . -    —— 排除 `/tmp/survey-x`、`/foo.md`
# 这条不与「不靠正文 grep 推断调用图」矛盾，两者判的是不同的事：
#   S5  判**会不会跑**（语义 —— 必须显式声明，grep 假阳性压倒真信号）
#   S10 判**这个名字还在不在**（字面 —— 可静态判定，与是否触发无关）
# 正文里写 `/foo-bar` 就是在告诉读者「有个叫 foo-bar 的 skill」；它不存在就是事实错误。
SKILL_REF_RE = re.compile(r"(?<![\w./~$}'\"-])/([a-z][a-z0-9]*(?:-[a-z0-9]+)+)(?![\w/.-])")

# 不在本仓库「已声明宇宙」里、但 S10 不该拦的 `/kebab-case`。
# 每条都必须写清为什么 —— 否则这个集合会变成静默放行一切的后门。
EXTERNAL_SLASH_REFS = {
    # Claude Code 内置 skill，不经 SSOT、也不该进 SKILLS.md 的收录集合
    "code-review", "security-review",
    # 上游 skill 家族里本仓库没引进的成员。SKILLS.md「已知缺失的能力」已就
    # plan-design-review / design-review-lite 立过规矩：**不改上游 skill 的正文**，
    # 避免与上游分叉。这几个同理，只出现在 zhao-lei007 / anthropics 的原文里。
    "design-review", "qa-only", "document-release", "skill-test",
}

SECTION_RE = re.compile(r"^##\s+(.+?)\s*$", re.M)
ENTRY_RE = re.compile(r"^###\s+`/?([a-z0-9][a-z0-9-]*)`", re.M)
# 「按项目分发」章节用表格而不是 ### 小节列条目，单独提取首列。
# 只并进「已声明宇宙」，不参与 S3/S4 的收录/计数对账。
TABLE_ENTRY_RE = re.compile(r"^\|\s*`/?([a-z0-9][a-z0-9-]*)`\s*\|", re.M)
COUNT_RE = re.compile(r"（(\d+)\s*个")


def parse_skills_md() -> dict[str, dict]:
    """把 SKILLS.md 切成章节 -> {标题, 声明的计数, 条目集合}。"""
    if not SKILLS_MD.exists():
        err("S3", "SKILLS.md 不存在")
        return {}
    text = SKILLS_MD.read_text(encoding="utf-8")
    marks = list(SECTION_RE.finditer(text))
    sections: dict[str, dict] = {}
    for i, m in enumerate(marks):
        title = m.group(1)
        body = text[m.end() : marks[i + 1].start() if i + 1 < len(marks) else len(text)]
        cm = COUNT_RE.search(title)
        sections[title] = {
            "declared_count": int(cm.group(1)) if cm else None,
            "entries": set(ENTRY_RE.findall(body)),
            "table_entries": set(TABLE_ENTRY_RE.findall(body)),
        }
    return sections


def find_section(sections: dict, keyword: str) -> tuple[str | None, dict]:
    for title, data in sections.items():
        if keyword in title:
            return title, data
    return None, {"declared_count": None, "entries": set(), "table_entries": set()}


# ---------------------------------------------------------------- SSOT 层

def check_ssot() -> tuple[set[str], set[str], set[str], dict[str, dict]]:
    if not SSOT_DIR.is_dir():
        err("S0", f"找不到 SSOT 目录 {SSOT_DIR}")
        return set(), set(), set(), {}

    dirs = {p.name for p in sorted(SSOT_DIR.iterdir()) if (p / "SKILL.md").is_file()}
    metas = {n: parse_frontmatter(SSOT_DIR / n / "SKILL.md") for n in dirs}

    sections = parse_skills_md()
    ssot_title, ssot_sec = find_section(sections, "SSOT 管理")
    local_title, local_sec = find_section(sections, "本地专用")
    plugin_title, plugin_sec = find_section(sections, "外部全局插件")
    _, missing_sec = find_section(sections, "已知缺失")
    known_missing = missing_sec["entries"]
    # 「按项目分发」的 skill 住在各自仓库里，本机全局看不到它们，但它们确实存在
    _, dist_sec = find_section(sections, "按项目分发")
    project_distributed = dist_sec["table_entries"]

    # 声明宇宙：一个引用只有落在这四类里才算可解析。「已知缺失」也算可解析，
    # 但每次都报 WARN——登记不等于修好，只是让缺口有名有姓而不是被抹掉。
    universe = (dirs | local_sec["entries"] | plugin_sec["entries"]
                | known_missing | project_distributed)

    for name in sorted(dirs):
        meta = metas[name]
        rel = f".rulesync/skills/{name}/SKILL.md"

        if meta.get("name") != name:
            err("S1", f"{rel}: frontmatter name=`{meta.get('name')}` 与目录名 `{name}` 不一致")
        if not meta.get("description"):
            err("S2", f"{rel}: description 缺失或为空")
        if meta.get("scope") not in ("global", "project"):
            err("S8", f"{rel}: scope=`{meta.get('scope')}` 不是合法值（global | project）")

        # S9 description 长度。超限是**静默**丢失——不报错、generate 照样 exit=0，
        # 而超出的那截往往正是你最后追加的触发词，于是"加了却没生效"且无从察觉。
        n = len(meta.get("description") or "")
        if n > DESC_LIMIT:
            err("S9", f"{rel}: description {n} 字符，超过上限 {DESC_LIMIT}，"
                      f"超出部分会被静默截断（把最关键的用途写在最前面）")
        elif n > DESC_WARN:
            warn("S9", f"{name}: description {n} 字符（上限 {DESC_LIMIT} 的 "
                       f"{n * 100 // DESC_LIMIT}%）——描述只会越加越长，"
                       f"下次再追加触发词前先精简")

        for field in ("invokes", "recommends"):
            for target in meta.get(field, []):
                if target not in universe:
                    err("S5", f"{name} 的 `{field}` 指向 `{target}`，但它不是任何已声明的 skill（断链）")
                elif target in known_missing:
                    warn("S5", f"{name} 的 `{field}` 指向 `{target}`，它已登记在 SKILLS.md"
                               f"「已知缺失的能力」——引用可解析，但该能力当前并不存在")
                elif field == "invokes" and metas.get(target, {}).get("user_invoked"):
                    err("S6", f"{name} 硬调用 `{target}`，但 `{target}` 已设为 "
                              f"disable-model-invocation（模型无法调用它）")

    # SKILLS.md 索引必须与实际目录双向一致
    if ssot_title:
        missing = dirs - ssot_sec["entries"]
        extra = ssot_sec["entries"] - dirs
        if missing:
            err("S3", f"SKILLS.md「{ssot_title}」漏收录：{', '.join(sorted(missing))}")
        if extra:
            err("S3", f"SKILLS.md「{ssot_title}」收录了不存在的 skill：{', '.join(sorted(extra))}")
        declared = ssot_sec["declared_count"]
        if declared is not None and declared != len(ssot_sec["entries"]):
            err("S4", f"SKILLS.md「{ssot_title}」标题写 {declared} 个，实际列出 "
                      f"{len(ssot_sec['entries'])} 个")
    else:
        err("S3", "SKILLS.md 找不到「SSOT 管理」章节")

    if local_title:
        declared = local_sec["declared_count"]
        if declared is not None and declared != len(local_sec["entries"]):
            err("S4", f"SKILLS.md「{local_title}」标题写 {declared} 个，实际列出 "
                      f"{len(local_sec['entries'])} 个")

    # 机器专属绝对路径不该出现在跨机器同步的 SSOT 里。
    # `~/.claude` 是各工具约定的标准位置，不算机器专属；`~/Desktop/...` 和
    # `/Users/...` 是。仓库搬过一次家（Desktop/AICAP → Desktop/AIProject/AICAP），
    # 写死的路径已经悄悄失效过好几处，所以这条是 ERROR 不是 WARN。
    for name in sorted(dirs):
        hits: list[str] = []
        for ln, line in enumerate(metas[name].get("_body", "").splitlines(), 1):
            for m in MACHINE_PATH_RE.finditer(line):
                hits.append(f"L{ln} `{m.group(0)}`")
        if hits:
            shown = "；".join(hits[:4]) + ("…" if len(hits) > 4 else "")
            err("S7", f".rulesync/skills/{name}/SKILL.md: {len(hits)} 处硬编码本机路径"
                      f"（{shown}）——SSOT 要跨机器可用，改成仓库相对路径或"
                      f"运行时定位（git rev-parse --show-toplevel）")

    # S10 正文 / description 里点名的 skill 必须真的存在。
    # S5 只看 frontmatter 声明的调用图，而「承诺一个不存在的衔接」几乎总是写在正文里：
    # survey 的对比表曾长期列着 borrow-open-source 与 harness-review-workflow，
    # req-discovery 的 Phase 4.5 曾写「衔接 /feature-fullstack」——门禁一条都没抓到，
    # 最后靠人眼审计才发现。承诺一个不会发生的衔接，比不承诺更坏。
    for name in sorted(dirs):
        meta = metas[name]
        seen: dict[str, str] = {}
        for label, text in (("description", meta.get("description") or ""),
                            ("正文", meta.get("_body") or "")):
            for ln, line in enumerate(text.splitlines(), 1):
                for m in SKILL_REF_RE.finditer(line):
                    seen.setdefault(m.group(1),
                                    label if label == "description" else f"正文 L{ln}")
        for target, where in sorted(seen.items()):
            if target == name or target in EXTERNAL_SLASH_REFS:
                continue
            if target in known_missing:
                warn("S10", f"{name} 的{where} 点名 `/{target}`，它已登记在 SKILLS.md"
                            f"「已知缺失的能力」——引用可解析，但该能力当前并不存在")
            elif target not in universe:
                err("S10", f"{name} 的{where} 点名 `/{target}`，但它不是任何已声明的 skill"
                           f"（SSOT / 本地专用 / 插件 / 已知缺失里都没有）——正文承诺一个"
                           f"不存在的衔接比不承诺更坏。确实要保留这个名字，就登记进 "
                           f"SKILLS.md「已知缺失的能力」（降为 WARN 留痕）")

    project_scoped = {n for n in dirs if metas[n].get("scope") == "project"}
    return dirs, local_sec["entries"], project_scoped, metas


# ---------------------------------------------------------------- 全局层

def check_global(ssot_dirs: set[str], declared_local: set[str],
                 project_scoped: set[str], strict: bool) -> None:
    skills_dir = GLOBAL_HOME / "skills"
    if not skills_dir.is_dir():
        print(f"  (跳过全局层：{skills_dir} 不存在——CI 环境正常)")
        return

    soft = err if strict else warn

    # G1 断链 symlink（skills 与 commands 两处）
    for sub in ("skills", "commands"):
        d = GLOBAL_HOME / sub
        if not d.is_dir():
            continue
        for entry in sorted(d.iterdir()):
            if entry.name.startswith("."):
                continue
            if entry.is_symlink() and not entry.exists():
                err("G1", f"{entry} → {os.readlink(entry)}  断链")

    # G3 SSOT skill 的 symlink 必须指向本仓库某个 checkout 的 .claude/skills
    valid_roots = [c / ".claude" / "skills" for c in repo_checkouts()]
    for entry in sorted(skills_dir.iterdir()):
        if not entry.is_symlink() or entry.name.startswith("."):
            continue
        if entry.name not in ssot_dirs:
            continue
        target = Path(os.readlink(entry))
        parents = target.resolve().parents
        if not any(root.resolve() in parents for root in valid_roots):
            soft("G3", f"~/.claude/skills/{entry.name} 是 SSOT skill，却指向 "
                       f"`{target}`（不在本仓库任何 checkout 的 .claude/skills 下）")

    # G5 声明为项目级的 skill 不该出现在全局发现面。声明与实际必须一致，
    # 否则 `scope: project` 就只是一句没人执行的注释。
    # 修复：pnpm run setup:skills（脚本会回收本仓库自己建的那条软链）
    for name in sorted(project_scoped):
        if (skills_dir / name).exists() or (skills_dir / name).is_symlink():
            err("G5", f"{name} 在 SSOT 里声明了 scope: project，却仍出现在 "
                      f"{skills_dir}/ —— 它会在所有无关项目里占上下文。"
                      f"跑 `pnpm run setup:skills` 回收")

    # G2 / G4 收录一致性
    present = {p.name for p in skills_dir.iterdir()
               if not p.name.startswith(".") and (p / "SKILL.md").is_file()}
    non_ssot_present = present - ssot_dirs
    unlisted = non_ssot_present - declared_local
    if unlisted:
        soft("G2", f"这些本机 skill 没被 SKILLS.md「本地专用」章节收录："
                   f"{', '.join(sorted(unlisted))}")
    ghost = declared_local - non_ssot_present
    if ghost:
        soft("G4", f"SKILLS.md 声明了但本机不存在的本地 skill：{', '.join(sorted(ghost))}")


def check_overrides(metas: dict[str, dict], strict: bool) -> None:
    """G6 本机 `skillOverrides` 把被引用的 skill 关到模型看不见。

    S6 只读 frontmatter 的 `disable-model-invocation`，读不到 settings 里的
    `skillOverrides`——于是「目录在、SKILLS.md 也登记了、但本机已经把它关掉」
    这一类失效，S5 / S6 / S10 全部绿灯。`feature-fullstack` 正是这样一路绿到
    2026-09-12 人眼审计才被发现的：它既硬编码了已不存在的项目路径，又早被设为 `off`。

    `~/.claude/settings.json` 是**个人文件**：CI 里不存在，队友机器也各不相同。
    所以读不到就安静跳过、绝不报错；读到才对账，且默认是黄不是红。
    """
    path = GLOBAL_HOME / "settings.json"
    if not path.is_file():
        print(f"  (跳过 G6：{path} 不存在——CI 环境正常)")
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print(f"  (跳过 G6：{path} 读不动或不是合法 JSON——个人文件，不因此报错)")
        return
    overrides = (data or {}).get("skillOverrides")
    if not isinstance(overrides, dict) or not overrides:
        return

    soft = err if strict else warn
    print(f"  G6：读到 {len(overrides)} 条 skillOverrides")

    # `off` = 模型和 `/` 菜单都没有；`user-invocable-only` = 对模型隐藏但人还能打 `/name`。
    # 所以 `invokes`（模型硬调用）碰上两者都算断；`recommends`（给人的路由）只有
    # `off` 才算断——菜单还在的话，这条路由对人依然成立。
    hidden = {"off": "模型与 `/` 菜单双向隐藏", "user-invocable-only": "对模型隐藏"}
    for name in sorted(metas):
        for field in ("invokes", "recommends"):
            for target in metas[name].get(field, []):
                level = overrides.get(target)
                if level not in hidden:
                    continue
                if field == "recommends" and level != "off":
                    continue
                soft("G6", f"{name} 的 `{field}` 指向 `{target}`，但本机 skillOverrides "
                           f"把 `{target}` 设成了 `{level}`（{hidden[level]}）——"
                           f"这类失效 S6 抓不到（S6 只读 frontmatter）。"
                           f"要么改 settings，要么把这条引用去掉")


# ---------------------------------------------------------------- main

def main() -> int:
    ssot_only = "--ssot-only" in sys.argv
    strict = "--strict-global" in sys.argv

    print("skill 门禁")
    print(f"  仓库：{REPO}")
    ssot_dirs, declared_local, project_scoped, metas = check_ssot()
    scoped = f"，其中 {len(project_scoped)} 个项目级不入全局" if project_scoped else ""
    print(f"  SSOT 层：{len(ssot_dirs)} 个 skill 已检查{scoped}")
    if ssot_only:
        print("  (--ssot-only：跳过全局层)")
    else:
        check_global(ssot_dirs, declared_local, project_scoped, strict)
        check_overrides(metas, strict)

    print()
    for w in warnings:
        print(f"  WARN  {w}")
    for e in errors:
        print(f"  ERROR {e}")

    print()
    if errors:
        print(f"✗ 失败：{len(errors)} 个错误，{len(warnings)} 个警告")
        return 1
    print(f"✓ 通过：0 个错误，{len(warnings)} 个警告")
    return 0


if __name__ == "__main__":
    sys.exit(main())
