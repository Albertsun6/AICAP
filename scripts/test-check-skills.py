#!/usr/bin/env python3
"""check-skills.py 自身的可执行验证。

一个只会说 OK 的门禁等于没有门禁。这里为**每一条规则**造一个合成违规，
断言门禁必须红、且红在正确的规则码上；再断言干净基线必须绿——
否则"绿"只能证明它什么都没检查。

跑：python3 scripts/test-check-skills.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

GATE = Path(__file__).resolve().parent / "check-skills.py"

CLEAN_SKILLS_MD = """# 技能清单

## SSOT 管理的 Skills（2 个，跨工具同步）

### `/alpha`
**用途**：甲。

---

### `/beta`
**用途**：乙。

---

## 本地专用 Skills（1 个，非 SSOT，仅本机）

### `/local-only`
**用途**：本机专属。

---

## 已知缺失的能力（被引用但未安装）

### `/gone-missing`
**现状**：不存在，登记留痕。
"""


def skill(name: str, *, desc: str = "做某件事。", extra: str = "", body: str = "正文。") -> str:
    return f"---\nname: {name}\ndescription: {desc}\n{extra}---\n\n# {name}\n\n{body}\n"


def make_fixture(root: Path) -> None:
    """一个干净的最小仓库：2 个 SSOT skill + 完整索引。"""
    (root / "scripts").mkdir(parents=True)
    shutil.copy(GATE, root / "scripts" / "check-skills.py")
    for n in ("alpha", "beta"):
        d = root / ".rulesync" / "skills" / n
        d.mkdir(parents=True)
        (d / "SKILL.md").write_text(skill(n), encoding="utf-8")
    (root / "SKILLS.md").write_text(CLEAN_SKILLS_MD, encoding="utf-8")


def run(root: Path, *, ssot_only: bool = True, config_dir: Path | None = None,
        strict: bool = False) -> tuple[int, str]:
    argv = [sys.executable, str(root / "scripts" / "check-skills.py")]
    if ssot_only:
        argv.append("--ssot-only")
    if strict:
        argv.append("--strict-global")
    env = os.environ.copy()
    if config_dir is not None:
        env["CLAUDE_CONFIG_DIR"] = str(config_dir)
    p = subprocess.run(argv, capture_output=True, text=True, timeout=60, env=env)
    return p.returncode, p.stdout + p.stderr


# ---------------------------------------------------------------- 各条违规

def v_s1(root: Path) -> None:
    p = root / ".rulesync" / "skills" / "alpha" / "SKILL.md"
    p.write_text(skill("alpha").replace("name: alpha", "name: alfa"), encoding="utf-8")


def v_s2(root: Path) -> None:
    p = root / ".rulesync" / "skills" / "alpha" / "SKILL.md"
    p.write_text("---\nname: alpha\ndescription:\n---\n\n# alpha\n", encoding="utf-8")


def v_s3_missing(root: Path) -> None:
    d = root / ".rulesync" / "skills" / "gamma"
    d.mkdir()
    (d / "SKILL.md").write_text(skill("gamma"), encoding="utf-8")


def v_s3_ghost(root: Path) -> None:
    shutil.rmtree(root / ".rulesync" / "skills" / "beta")


def v_s4(root: Path) -> None:
    p = root / "SKILLS.md"
    p.write_text(p.read_text(encoding="utf-8").replace("（2 个，跨工具同步）",
                                                       "（7 个，跨工具同步）"), encoding="utf-8")


def v_s5(root: Path) -> None:
    p = root / ".rulesync" / "skills" / "alpha" / "SKILL.md"
    p.write_text(skill("alpha", extra='invokes: ["does-not-exist"]\n'), encoding="utf-8")


def v_s6(root: Path) -> None:
    """alpha 硬调用 beta，而 beta 关掉了模型调用——评审 #2 指出的那个冲突。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", extra='invokes: ["beta"]\n'), encoding="utf-8")
    (root / ".rulesync" / "skills" / "beta" / "SKILL.md").write_text(
        skill("beta", extra="claudecode:\n  disable-model-invocation: true\n"), encoding="utf-8")


def v_s6_ok(root: Path) -> None:
    """同样的 user-invoked skill，出现在 recommends 里是合法的——不该红。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", extra='recommends: ["beta"]\n'), encoding="utf-8")
    (root / ".rulesync" / "skills" / "beta" / "SKILL.md").write_text(
        skill("beta", extra="claudecode:\n  disable-model-invocation: true\n"), encoding="utf-8")


def v_s5_local_ok(root: Path) -> None:
    """指向 SKILLS.md 本地专用章节里声明的 skill，可解析——不该红。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", extra='recommends: ["local-only"]\n'), encoding="utf-8")


def v_s5_known_missing(root: Path) -> None:
    """指向已登记的缺失能力：可解析、不红，但必须报 WARN 留痕。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", extra='invokes: ["gone-missing"]\n'), encoding="utf-8")


def v_s5_unregistered(root: Path) -> None:
    """没登记的缺失能力仍必须红——否则「登记」这个机制等于给所有断链开后门。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", extra='invokes: ["never-registered"]\n'), encoding="utf-8")


def v_s7(root: Path) -> None:
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", body="先 `cd ~/Desktop/AICAP` 再跑。"), encoding="utf-8")


def v_s8(root: Path) -> None:
    """scope 只认 global / project，写错必须红——否则拼错就静默退化成全局。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", extra="scope: proejct\n"), encoding="utf-8")


def v_s8_ok(root: Path) -> None:
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", extra="scope: project\n"), encoding="utf-8")


def v_s9_over(root: Path) -> None:
    """description 超 1024 必须红——超出部分会被静默截断，正是最后追加的触发词。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", desc="超长描述。" * 300), encoding="utf-8")


def v_s9_warn(root: Path) -> None:
    """过警戒线（>800）但未超限：应通过，但必须留 WARN。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", desc="接近上限的描述。" * 110), encoding="utf-8")


def v_block_scalar_not_leaking(root: Path) -> None:
    """块标量 description 之后的其他键不得被吸进 description。

    异构评审（gpt-5.6）指出的洞，实测确认在跑：旧解析器收「description 之后所有
    缩进行」，于是 `allowed-tools:` 的 YAML 列表项也算进了 description——
    plan-ceo-review +56 字符、plan-eng-review +66、pre-land-review +75、
    xcuitest-skill +63，而 `build-skill-index.py` 还把 `- Read`、`- Bash`
    这些工具名当触发词喂给了 eval。

    这条用例的构造：真实 description 780 字符（低于 800 警戒线），后面跟一段
    足够长的 allowed-tools 列表。解析正确 → 无 S9 警告；一旦又把块外内容
    吸进来 → 总长过线 → 冒出一条不该有的 S9 WARN，测试失败。
    """
    desc = "块内的真实描述。" * 88            # 8 字 × 88 = 704，低于 800 警戒线
    tools = "\n".join(f"  - Tool{i:02d}" for i in range(20))  # 块外 ≈220 字符：
    #                                          泄漏则 704+220 = 924 > 800 → 冒 WARN
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        f"---\nname: alpha\ndescription: |\n  {desc}\nallowed-tools:\n{tools}\n---\n\n# alpha\n\n正文。\n",
        encoding="utf-8")


def v_s10(root: Path) -> None:
    """正文点名一个不存在的 skill —— PR #1 手工修的正是这一类，当时门禁没抓到。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", body="写完需求可以直接衔接 `/no-such-skill` 进入实施。"),
        encoding="utf-8")


def v_s10_desc(root: Path) -> None:
    """description 里点名的同样算 —— 那是唯一进模型上下文的字段。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", desc="做某件事，完事后交给 /no-such-skill 收尾。"), encoding="utf-8")


def v_s10_ok(root: Path) -> None:
    """点名 SKILLS.md 已登记的本地专用 skill：可解析，不该红、也不该警。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", body="详见 `/local-only` 的说明。"), encoding="utf-8")


def v_s10_known_missing(root: Path) -> None:
    """点名已登记的缺失能力：可解析、不红，但必须 WARN 留痕（与 S5 同待遇）。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", body="研究阶段先用 `/gone-missing` 出一份带引用的报告。"),
        encoding="utf-8")


def v_s10_external(root: Path) -> None:
    """Claude Code 内置 skill 不在本仓库宇宙里，但点名它是对的，不该红。"""
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", body="单个 PR 的逐行评审是 `/code-review` 的活，不是本 skill。"),
        encoding="utf-8")


def v_s10_no_false_positive(root: Path) -> None:
    """路径 / shell 展开 / URL / `A/B` 都不是 skill 引用 —— S10 的假阳性回归。

    仓库里真实存在这些写法：`survey` 把中间产物写到 /tmp、`install-skill` 用
    `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills` 定位全局目录、正文里到处是 GitHub URL。
    匹配器一旦放宽（不要求连字符、或忘了排除路径上下文），它们就会变成一片红，
    而唯一的"修法"是去改无辜的正文 —— 那时这条规则就从资产变成了负债。
    """
    body = "\n".join([
        "中间产物写到 /tmp，prompt 文件是 `/tmp/survey-x1-prompt.txt`。",
        'GLOBAL_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"',
        "见 https://github.com/anthropics/skills/blob/main/skills/web-artifacts-builder/SKILL.md",
        "对照 A/B-test 与 读/写 分离；相对路径 ./rel-path/x-y 也不算引用。",
    ])
    (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
        skill("alpha", body=body), encoding="utf-8")


def check_g5() -> list[str]:
    """全局层 G5：声明了 scope: project 却仍在全局发现面 → 必须红；回收后 → 绿。

    这条是「声明」与「实际」的对账。没有它，`scope: project` 就只是一句
    没人执行的注释——脚本忘了跑、或有人手工建了软链，都不会有人发现。
    """
    problems: list[str] = []
    for present, expect_red in ((True, True), (False, False)):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "repo"
            root.mkdir()
            make_fixture(root)
            v_s8_ok(root)                       # alpha 声明为项目级
            cfg = Path(td) / "cfg"
            (cfg / "skills").mkdir(parents=True)
            if present:
                (cfg / "skills" / "alpha").mkdir()   # 却仍出现在全局
            code, out = run(root, ssot_only=False, config_dir=cfg)

        label = "项目级 skill 仍在全局" if present else "项目级 skill 已回收"
        red = "[G5]" in out
        if red != expect_red:
            problems.append(f"G5「{label}」：期望{'红' if expect_red else '不红'}，实际相反\n{out}")
            print(f"  ✗ G5 {label}")
        else:
            print(f"  ✓ G5 {label} → {'红' if red else '绿'}，exit={code}")
    return problems


def check_g6() -> list[str]:
    """全局层 G6：本机 `skillOverrides` 把被引用的 skill 关到模型看不见。

    这是 S6 的盲区 —— S6 只读 frontmatter 的 `disable-model-invocation`，而
    `skillOverrides` 住在 `~/.claude/settings.json`。六种情形都要钉住，其中最关键的
    是最后一条：**读不到 settings 必须安静跳过**。CI 里根本没有这个文件，一报错就等于
    把门禁绑死在某台机器的个人配置上。
    """
    problems: list[str] = []
    cases = [
        # (说明, alpha 的 frontmatter, skillOverrides（None = 不写 settings.json）,
        #  是否 --strict-global, 期望出现的 G6 行；None = 不该出现 G6)
        ("invokes 指向被设为 off 的 skill",
         'invokes: ["beta"]\n', {"beta": "off"}, False, "WARN  [G6]"),
        ("同一情形加 --strict-global 升为错误",
         'invokes: ["beta"]\n', {"beta": "off"}, True, "ERROR [G6]"),
        ("invokes 指向 user-invocable-only（模型照样调不动）",
         'invokes: ["beta"]\n', {"beta": "user-invocable-only"}, False, "WARN  [G6]"),
        ("recommends 指向 user-invocable-only（人还能打 /name，不该报）",
         'recommends: ["beta"]\n', {"beta": "user-invocable-only"}, False, None),
        ("被降档的 skill 没人引用（用户自己的选择，不该唠叨）",
         "", {"beta": "off"}, False, None),
        ("没有 settings.json（CI 环境）必须安静跳过",
         'invokes: ["beta"]\n', None, False, None),
    ]
    for label, extra, overrides, strict, expect in cases:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "repo"
            root.mkdir()
            make_fixture(root)
            (root / ".rulesync" / "skills" / "alpha" / "SKILL.md").write_text(
                skill("alpha", extra=extra), encoding="utf-8")
            cfg = Path(td) / "cfg"
            (cfg / "skills").mkdir(parents=True)
            if overrides is not None:
                (cfg / "settings.json").write_text(
                    json.dumps({"skillOverrides": overrides}), encoding="utf-8")
            code, out = run(root, ssot_only=False, config_dir=cfg, strict=strict)

        if expect is None:
            if "[G6]" in out:
                problems.append(f"G6「{label}」：不该报 G6 却报了\n{out}")
                print(f"  ✗ G6 {label} → 误报")
            else:
                print(f"  ✓ G6 {label} → 未报，exit={code}")
        elif expect not in out:
            problems.append(f"G6「{label}」：期望出现 `{expect}`，实际没有\n{out}")
            print(f"  ✗ G6 {label} → 缺 `{expect.strip()}`")
        else:
            print(f"  ✓ G6 {label} → {expect.strip()}，exit={code}")
    return problems


CASES: list[tuple[str, callable, str | None]] = [
    # (名称, 注入函数, 期望的规则码；None = 期望通过)
    ("S1 name 与目录名不一致",              v_s1,           "S1"),
    ("S2 description 为空",                 v_s2,           "S2"),
    ("S3 SKILLS.md 漏收录新 skill",         v_s3_missing,   "S3"),
    ("S3 SKILLS.md 收录了不存在的 skill",   v_s3_ghost,     "S3"),
    ("S4 章节标题计数不符",                 v_s4,           "S4"),
    ("S5 invokes 指向不存在的 skill",       v_s5,           "S5"),
    ("S6 硬调用一个 user-invoked skill",    v_s6,           "S6"),
    ("S7 硬编码本机路径",                   v_s7,           "S7"),
    ("S5 未登记的缺失能力仍必须红",         v_s5_unregistered, "S5"),
    ("S8 scope 值拼错必须红",               v_s8,           "S8"),
    ("S9 description 超 1024 必须红",       v_s9_over,      "S9"),
    ("(应通过) user-invoked 出现在 recommends", v_s6_ok,    None),
    ("(应通过) 引用 SKILLS.md 声明的本地 skill", v_s5_local_ok, None),
    ("(应通过带警告) 引用已登记的缺失能力", v_s5_known_missing, None),
    ("(应通过带警告) description 过警戒线未超限", v_s9_warn, None),
    ("(应通过) scope: project 合法声明",    v_s8_ok,        None),
    ("(应通过) 块标量后的其他键不被算进 description", v_block_scalar_not_leaking, None),
    ("S10 正文点名不存在的 skill",             v_s10,          "S10"),
    ("S10 description 点名不存在的 skill",    v_s10_desc,     "S10"),
    ("(应通过) 正文点名本地专用 skill",        v_s10_ok,       None),
    ("(应通过带警告) 正文点名已登记的缺失能力", v_s10_known_missing, None),
    ("(应通过) 正文点名 Claude Code 内置 skill", v_s10_external, None),
    ("(应通过) 路径/shell/URL 不被当成 skill 引用", v_s10_no_false_positive, None),
]

# 期望通过、但必须留下 WARN 的用例（登记 ≠ 修好，不能静默放行）
MUST_WARN = {"(应通过带警告) 引用已登记的缺失能力",
             "(应通过带警告) description 过警戒线未超限",
             "(应通过带警告) 正文点名已登记的缺失能力"}

# 期望通过、且**不许**出现某规则告警的用例。少了这一档，"解析多算了长度"
# 只会表现为一条多余的 WARN——exit 仍是 0，测试照样绿，洞就留住了。
MUST_NOT_WARN = {"(应通过) 块标量后的其他键不被算进 description": "S9",
                 "(应通过) 正文点名本地专用 skill": "S10",
                 "(应通过) 正文点名 Claude Code 内置 skill": "S10",
                 "(应通过) 路径/shell/URL 不被当成 skill 引用": "S10"}


def main() -> int:
    failures: list[str] = []

    # 干净基线必须绿——否则后面每条"红"都可能是背景噪音
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        make_fixture(root)
        code, out = run(root)
        if code != 0:
            failures.append(f"干净基线本应通过，却失败了：\n{out}")
            print("  ✗ 干净基线")
        else:
            print("  ✓ 干净基线通过（exit=0）")

    for name, inject, expect in CASES:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_fixture(root)
            inject(root)
            code, out = run(root)

        if expect is None:
            if code != 0:
                failures.append(f"{name}: 本应通过却红了\n{out}")
                print(f"  ✗ {name} → 误报")
            elif name in MUST_WARN and "WARN" not in out:
                failures.append(f"{name}: 通过了但没留 WARN——等于静默放行\n{out}")
                print(f"  ✗ {name} → 缺 WARN")
            elif name in MUST_NOT_WARN and f"[{MUST_NOT_WARN[name]}]" in out:
                rule = MUST_NOT_WARN[name]
                failures.append(f"{name}: 冒出了不该有的 {rule} 告警\n{out}")
                print(f"  ✗ {name} → 多余的 {rule} 告警")
            else:
                suffix = "（带 WARN）" if name in MUST_WARN else ""
                print(f"  ✓ {name} → 通过{suffix}")
            continue

        if code == 0:
            failures.append(f"{name}: 门禁没红（漏报！）\n{out}")
            print(f"  ✗ {name} → 漏报")
        elif f"[{expect}]" not in out:
            failures.append(f"{name}: 红了但不是 {expect}\n{out}")
            print(f"  ✗ {name} → 红在别的规则上")
        else:
            print(f"  ✓ {name} → {expect} 触发，exit={code}")

    # 全局层：G5 / G6 各自起一个临时 CLAUDE_CONFIG_DIR 做「声明 vs 实际」的对账。
    # 它们不走 CASES（需要伪造 ~/.claude，不只是改仓库内容）。
    failures += check_g5()
    failures += check_g6()

    print()
    if failures:
        print(f"✗ {len(failures)} 项未通过\n")
        for f in failures:
            print(f + "\n")
        return 1
    print(f"✓ 全部 {len(CASES) + 1} 项 + 全局层 G5/G6 对账通过："
          f"每条规则都被证明能红，且不误报")
    return 0


if __name__ == "__main__":
    sys.exit(main())
