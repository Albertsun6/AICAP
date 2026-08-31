#!/usr/bin/env python3
"""从 SSOT 生成触发 eval 用的 skill 索引。

eval 要问的是「给模型和 Claude Code 一样的 name + description，它能不能挑对」。
索引必须来自 `.rulesync/skills/`，不能手抄——手抄的索引会跟 SSOT 漂移，
到时候 eval 通过只说明它跟一份过时清单一致。

只收 SSOT 的 24 个:CI 里没有 `~/.claude/skills`,本机专属 skill 不可复现。
所以测试用例里的期望答案也只能是 SSOT skill 或 NONE。

用法：python3 promptfoo/build-skill-index.py > promptfoo/skill-index.txt
"""

import re
import sys
from pathlib import Path

SSOT = Path(__file__).resolve().parent.parent / ".rulesync" / "skills"


def description(text: str) -> str:
    """取 frontmatter 里的 description，折叠成单行。"""
    if not text.startswith("---\n"):
        return ""
    end = text.find("\n---\n", 3)
    fm = text[4:end] if end != -1 else text[4:]
    m = re.search(r"^description:\s*(.*)$", fm, re.M)
    if not m:
        return ""
    inline = m.group(1).strip()
    if inline and inline not in (">", ">-", "|", "|-"):
        return inline.strip("\"'")
    # 块标量：只收**连续的**缩进行，遇到第一个非缩进的非空行就停（那是下一个键）。
    # 旧写法收「所有」缩进行，把 `allowed-tools:` 的列表项(`- Read`)也吸进了
    # description，于是 eval 索引里混进工具名当触发词喂给模型——4 个 skill 中招。
    body: list[str] = []
    for ln in fm[m.end():].splitlines():
        if ln.startswith((" ", "\t")):
            body.append(ln.strip())
        elif not ln.strip():
            continue        # 块内空行：分段用，折叠成单行时直接丢
        else:
            break
    return " ".join(x for x in body if x)


def main() -> int:
    if not SSOT.is_dir():
        print(f"找不到 {SSOT}", file=sys.stderr)
        return 1
    lines = []
    for d in sorted(SSOT.iterdir()):
        f = d / "SKILL.md"
        if not f.is_file():
            continue
        desc = description(f.read_text(encoding="utf-8", errors="replace"))
        lines.append(f"- {d.name}: {desc}")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
