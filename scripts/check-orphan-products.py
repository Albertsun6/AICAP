#!/usr/bin/env python3
"""查「入库了、但 generate 已经不再产出」的孤儿产物。

drift gate（`rulesync generate && git diff --exit-code`）有一个结构性盲区：
它只能发现**内容不一致**，发现不了**整棵树被遗弃**。generate 从不触碰那棵树，
所以它永远不会 diff——只会安静地无限漂移下去。

这不是假想。rulesync 8.18 → 16.2 升级时，codexcli 的 skill 输出位置从
`.codex/skills/` 改到了 `.agents/skills/`。升级那次 commit 新增了 `.agents/`
（198 个文件，还专门写了说明），却没人发现 `.codex/skills/` 的 199 个文件
从此变成死的：内容当时还一样，但 SSOT 一改就开始分叉，而 CI 全绿。

检测办法（通用，不写死任何路径）：把 SSOT 生成到一个临时目录，
拿「新鲜产出的文件集」当真值，比对版本控制里落在同样产物根下的文件。
入库有、新鲜产出没有 = 孤儿。rulesync 换输出路径、砍掉某个 feature、
或者有人手工往产物目录里塞文件，这三种都能抓到。

用法：
    python3 scripts/check-orphan-products.py            # 有孤儿则非零退出
    python3 scripts/check-orphan-products.py --list     # 只列出，总是 0 退出

依赖网络（`npx rulesync@<版本>`），所以**不放进 check-skills.py**——
那个门禁是纯静态的、跑得飞快，不该被拖成分钟级。
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# 住在产物根下、但**不是** rulesync 产出的手写文件。
# 少一条会误报、多一条会漏报，所以每条都要写清楚为什么。
ALLOWLIST = {
    # 我们自己写的 CI 配置。它住在 .github/ 下纯属 GitHub 的约定，与 rulesync 无关。
    ".github/workflows/",
}


def rulesync_version() -> str:
    """从 package.json 读 pin 住的版本，避免这里和 CI 用不同版本比出假差异。"""
    pkg = json.loads((REPO / "package.json").read_text(encoding="utf-8"))
    v = (pkg.get("devDependencies") or {}).get("rulesync")
    if not v:
        sys.exit("package.json 的 devDependencies 里没有 rulesync，无法确定版本")
    return re.sub(r"^[\^~]", "", v)


def tracked_files() -> set[str]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout
    return set(out.split())


def generate_to(tmp: Path, version: str) -> set[str]:
    r = subprocess.run(
        ["npx", "-y", f"rulesync@{version}", "generate", "-o", str(tmp)],
        cwd=REPO, capture_output=True, text=True, timeout=900,
    )
    if r.returncode != 0:
        sys.exit(f"generate 失败（exit={r.returncode}）：\n{r.stdout}\n{r.stderr}")
    # generate 可能在仓库根留下 pnpm 的产物，别把它算进改动
    return {str(p.relative_to(tmp)) for p in tmp.rglob("*") if p.is_file()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="只列出孤儿，不因此失败")
    args = ap.parse_args()

    version = rulesync_version()
    with tempfile.TemporaryDirectory() as td:
        fresh = generate_to(Path(td), version)

    # 产物根 = 新鲜产出里出现过的顶层路径段。只在这些根下面找孤儿，
    # 免得把 src/、docs/ 这些跟 rulesync 无关的目录卷进来。
    roots = {f.split("/")[0] for f in fresh}
    orphans = sorted(
        f for f in tracked_files()
        if f.split("/")[0] in roots
        and f not in fresh
        and not any(f.startswith(a) for a in ALLOWLIST)
    )

    print(f"rulesync@{version}｜产物根 {len(roots)} 个：{' '.join(sorted(roots))}")
    print(f"新鲜产出 {len(fresh)} 个文件")

    if not orphans:
        print("✓ 无孤儿：每个入库的产物文件都还在被 generate 产出")
        return 0

    # 按目录聚合——一棵死树往往是几百个文件，逐个列没法看
    groups: dict[str, int] = {}
    for o in orphans:
        groups["/".join(o.split("/")[:2])] = groups.get("/".join(o.split("/")[:2]), 0) + 1

    print(f"\n{'⚠' if args.list else '✗'} 发现 {len(orphans)} 个孤儿产物"
          f"（入库了，但 generate 已不再产出）：")
    for k, v in sorted(groups.items(), key=lambda x: -x[1]):
        print(f"    {k}/  → {v} 个文件")
    print("\n  这些文件 drift gate 永远抓不到：generate 不触碰它们，所以不会 diff，"
          "\n  只会随 SSOT 变更无声漂移。确认无用就 `git rm -r` 掉；"
          "\n  若是手写的非产物文件，加进本脚本的 ALLOWLIST 并写明理由。")
    return 0 if args.list else 1


if __name__ == "__main__":
    sys.exit(main())
