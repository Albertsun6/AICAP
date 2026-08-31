#!/usr/bin/env python3
"""用 Claude Code 订阅跑触发 eval —— 不需要 ANTHROPIC_API_KEY。

promptfoo 的 anthropic provider 要 API key。这个 runner 改用 `claude -p`，
走的是已经在付费的 Claude Code 订阅；而且它用的就是 Claude Code 真实做 skill
路由时用的那个模型，比打 API 更贴近要测的链路。

用例、prompt 模板、断言都直接读 promptfoo/trigger-eval.yaml —— 同一份，
不维护第二套，否则两个 runner 迟早各测各的。

用法：
    python3 promptfoo/run-trigger-eval.py            # 全部
    python3 promptfoo/run-trigger-eval.py -k 提交     # 只跑描述里含"提交"的
    python3 promptfoo/run-trigger-eval.py -v         # 失败时打印模型原始输出

CI 上仍走 promptfoo（有密钥时），见 .github/workflows/ai-config-drift.yml。
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG = HERE / "trigger-eval.yaml"
BUILD_INDEX = HERE / "build-skill-index.py"

# Claude Code 默认会带上自己的整套系统提示、CLAUDE.md、工具集**以及本机真实的
# skill 清单**——最后这条最阴：模型会拿本机 skill（含不在 SSOT 索引里的本地专用
# skill）来回答，测出来的就不是"我给的这份索引可不可分辨"，而是"它记不记得本机装
# 了什么"。实测过：不加 --disable-slash-commands 时它会答出索引里根本没有的
# report-to-audio。全部关掉，只留一句最小指令。
CLAUDE_ARGS = [
    "--model", "opus",
    "--system-prompt", "严格按用户消息里的要求作答。只输出要求的内容，不解释、不寒暄。",
    "--disable-slash-commands",   # 关键：不让本机真实 skill 清单混进上下文
    "--disallowed-tools", "Bash Read Write Edit Glob Grep WebSearch WebFetch Task",
    "--no-session-persistence",
    "--strict-mcp-config",
]


def build_index() -> str:
    out = subprocess.run([sys.executable, str(BUILD_INDEX)],
                         capture_output=True, text=True, check=True)
    return out.stdout.rstrip("\n")


def load_config() -> tuple[str, list[dict]]:
    try:
        import yaml
    except ImportError:
        sys.exit("需要 PyYAML 才能读用例：pip3 install pyyaml")
    cfg = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    prompts = cfg.get("prompts") or []
    if len(prompts) != 1:
        sys.exit(f"预期 trigger-eval.yaml 只有 1 个 prompt 模板，实际 {len(prompts)} 个")
    return prompts[0], cfg.get("tests") or []


def expected_of(test: dict) -> str | None:
    """从 assert 里取那条正则——用例的期望答案就写在里面。"""
    for a in test.get("assert") or []:
        if a.get("type") == "regex":
            return a.get("value")
    return None


def ask(prompt: str, cwd: str) -> str:
    """在中立目录跑，避免当前仓库的 CLAUDE.md 被自动带进上下文。"""
    p = subprocess.run(["claude", "-p", *CLAUDE_ARGS],
                       input=prompt, capture_output=True, text=True,
                       cwd=cwd, timeout=180)
    if p.returncode != 0:
        return f"<claude 退出码 {p.returncode}: {(p.stderr or '').strip()[:200]}>"
    return p.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", metavar="KEYWORD", help="只跑 description 含该关键字的用例")
    ap.add_argument("-v", action="store_true", help="失败时打印模型原始输出")
    args = ap.parse_args()

    template, tests = load_config()
    if args.k:
        tests = [t for t in tests if args.k in (t.get("description") or "")]
    if not tests:
        sys.exit("没有匹配的用例")

    index = build_index()
    print(f"触发 eval · {len(tests)} 个用例 · 经 Claude Code 订阅（无需 API key）\n")

    passed, failed = 0, []
    with tempfile.TemporaryDirectory() as neutral:
        for i, t in enumerate(tests, 1):
            desc = t.get("description", "(无描述)")
            utterance = (t.get("vars") or {}).get("utterance", "")
            pattern = expected_of(t)
            if not pattern:
                print(f"  ?  [{i}/{len(tests)}] {desc} —— 没有 regex 断言，跳过")
                continue

            prompt = template.replace("{{skillIndex}}", index).replace("{{utterance}}", utterance)
            answer = ask(prompt, neutral)

            if re.search(pattern, answer):
                passed += 1
                print(f"  ✓  [{i}/{len(tests)}] {desc}")
            else:
                want = pattern.strip("^$\\s").replace("\\s*", "")
                failed.append((desc, want, answer))
                print(f"  ✗  [{i}/{len(tests)}] {desc}")
                print(f"       期望 {want}  实际 {answer[:80]!r}")
                if args.v:
                    print(f"       原始输出：\n{answer}\n")

    print()
    total = passed + len(failed)
    if failed:
        print(f"✗ {passed}/{total} 通过，{len(failed)} 条未过：")
        for desc, want, got in failed:
            print(f"  · {desc}\n      期望 {want} / 实际 {got[:60]!r}")
        print("\n注意：失败往往说明两个 skill 的 description 边界糊，需要收敛描述——")
        print("不一定是用例写错了。改完 description 再跑一次比对。")
        return 1
    print(f"✓ {passed}/{total} 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
