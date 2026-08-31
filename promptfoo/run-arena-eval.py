#!/usr/bin/env python3
"""竞技场 eval —— 真跑 `claude -p`，看 24 个 skill 同场竞争时**实际**触发了谁。

跟 promptfoo/run-trigger-eval.py 的关系：那个问模型「该触发哪个」（元认知问询），
这个不问，直接跑真实 agent 看它**做了什么**（行为测量）。模型说它会触发什么
≠ 它实际触发什么，两者都要。

设计吸收了对 Anthropic 官方 skill-creator 的异构评审（GPT-5.6 + Gemini-3.1-pro
独立评审，多条结论一致）。它那套的四个缺陷，这里逐条避开：

1. **不提前终止**。它遇到第一个非 Skill/Read 工具就 return False，于是
   「先 Glob 勘探再调 skill」这种正常流程全被误判成未触发——实测确认过
   （一条正例被判 0 触发，手工跑却看到第一个工具就是 Skill）。这里解析
   **完整轨迹**，收集全部 Skill 调用。
2. **基础设施错误绝不计作「未触发」**。它把超时 / CLI 失败 / 认证错误
   一律 `append(False)`，对正例造成红、对负例造成**假绿**——不对称污染。
   这里单列 ERROR 状态，不参与 pass/fail 统计。
3. **全 skill 同场竞争，不做单 skill 孤岛**。它一次只注入一个 skill，于是
   评分会奖励「贪婪型描述」——自己更容易触发，代价是抢邻居的活，而它测不到
   这个代价。两只异构眼都把这条列为最该改的一件事。
4. **不改 skill 的 name**。它把 `report-to-html` 换成
   `report-to-html-skill-<hex>` 再测，而 name 本身是路由信号——等于在优化
   description 的同时随机改了另一个变量。这里用真实 skill、真实名字。

候选集怎么受控：`~/.claude/skills` 的 personal 层覆盖 project 层，所以 SSOT
skill 本来就在场；在临时项目里用 `skillOverrides` 把不相干的本地 skill 关掉，
再 `disableBundledSkills` 关掉内置的。（不能用空的 CLAUDE_CONFIG_DIR 做隔离——
订阅凭据也存在那个目录里，实测会 "Not logged in"。）

期望值是**集合**而非单选：真实请求可能该触发 0 个、1 个或多个 skill。

用法：
    python3 promptfoo/run-arena-eval.py                 # 全部用例
    python3 promptfoo/run-arena-eval.py -k 近邻          # 只跑描述含关键字的
    python3 promptfoo/run-arena-eval.py --runs 3        # 每条采样 3 次
    python3 promptfoo/run-arena-eval.py -v              # 打印完整工具轨迹
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG = HERE / "trigger-eval.yaml"

# 这些是本机 ~/.claude/skills 里的非 SSOT skill：它们不在本仓库管辖内，
# 也不该参与本仓库 skill 的路由竞争，跑之前一律关掉。
NON_SSOT = [
    "archi-strategy-decode", "browser-handoff", "demo-video", "deploy-team-webapp",
    "feature-fullstack", "fedex-tracker", "ios-e2e-test", "report-to-audio", "short-drama",
]

# 允许勘探（Read/Glob/Grep），禁止一切破坏性与外发操作。
# 保留勘探是有意的：异构评审指出，「先看一眼文件再决定用哪个 skill」是正常
# 且常见的路径，禁掉它会让测出来的行为偏离真实。
DENY_TOOLS = "Write Edit NotebookEdit Bash WebFetch WebSearch Task"

# 首次检测到 skill 调用后，只再观察这么久就收工。重型 skill 被触发后会真的
# 开始跑（survey 的多阶段调研、project-health 的四层评估），等它结束必然超时——
# 而那个超时跟「触发准确度」毫无关系。实测：不早停时 10 条里 4 条被误记成 ERROR。
SETTLE_SECS = 12


def load_cases(keyword: str | None) -> list[dict]:
    """复用 trigger-eval.yaml 的用例 —— 不维护第二套，否则两个 runner 迟早各测各的。

    那边的断言是「输出恰好等于某个 name」的正则；这里把期望的 name 抽出来当
    期望集合，`NONE` 对应空集。
    """
    try:
        import yaml
    except ImportError:
        sys.exit("需要 PyYAML：pip3 install pyyaml")
    cfg = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    cases = []
    for t in cfg.get("tests") or []:
        desc = t.get("description", "")
        if keyword and keyword not in desc:
            continue
        utterance = (t.get("vars") or {}).get("utterance", "")
        expected: set[str] = set()
        for a in t.get("assert") or []:
            if a.get("type") != "regex":
                continue
            m = re.search(r"\^\\s\*([a-zA-Z0-9-]+)\\s\*\$", a.get("value", ""))
            if m and m.group(1) != "NONE":
                expected.add(m.group(1))
        if utterance:
            cases.append({"description": desc, "utterance": utterance, "expected": expected})
    return cases


def _write_skeleton(root: Path) -> None:
    """一个有真实调用关系的多模块骨架。

    为什么不能更简单：模型只在「自己不容易搞定」时才去查 skill（官方文档明说，
    异构评审也独立提到）。骨架第一版 auth 只有一个 4 行函数，于是「画一下 auth
    模块的调用图」这条用例里，模型原话是 *"a single file with a single function,
    so the call graph is small and I can [do it myself]"* —— 直接自己画了，
    `diagramming-code` 一次都没触发。那条红反映的是骨架太简单，不是描述不好。

    为什么不能更复杂：这不是要造一个真项目，只要让「画调用图 / 评估架构」这类
    请求成为**值得动用 skill** 的任务即可。
    """
    files = {
        "README.md": "# demo-service\n\nTypeScript 服务：鉴权、报表、任务调度三个模块，"
                     "共用 utils 下的日志与配置。\n",
        "package.json": '{\n  "name": "demo-service",\n  "version": "0.3.1",\n'
                        '  "scripts": { "test": "vitest", "build": "tsc", "lint": "eslint ." }\n}\n',
        "src/index.ts":
            'import { authGuard } from "./auth/middleware";\n'
            'import { buildReport } from "./report/build";\n'
            'import { schedule } from "./jobs/scheduler";\n'
            'import { log } from "./utils/logger";\n\n'
            'export async function handle(req: Request) {\n'
            '  const s = await authGuard(req);\n'
            '  if (!s) { log("denied"); return new Response("denied", { status: 401 }); }\n'
            '  schedule(() => buildReport(s.userId));\n'
            '  return new Response("ok");\n}\n',
        "src/auth/token.ts":
            'import { log } from "../utils/logger";\nimport { cfg } from "../utils/config";\n\n'
            'export function sign(uid: string): string {\n'
            '  return `${uid}.${Math.floor(Date.now() / 1000) + cfg.ttl}`;\n}\n\n'
            'export function verify(token: string): boolean {\n'
            '  const exp = Number(token.split(".")[1] ?? 0);\n'
            '  const ok = exp > Date.now() / 1000;\n  if (!ok) log("token expired");\n'
            '  return ok;\n}\n\n'
            'export function refresh(token: string): string | null {\n'
            '  if (!verify(token)) return null;\n'
            '  return sign(token.split(".")[0]);\n}\n',
        "src/auth/session.ts":
            'import { verify, refresh } from "./token";\nimport { log } from "../utils/logger";\n\n'
            'export interface Session { userId: string }\n\n'
            'const store = new Map<string, Session>();\n\n'
            'export function createSession(token: string): Session | null {\n'
            '  if (!verify(token)) return null;\n'
            '  const s = { userId: token.split(".")[0] };\n'
            '  store.set(token, s);\n  log("session created");\n  return s;\n}\n\n'
            'export function validateSession(token: string): Session | null {\n'
            '  const s = store.get(token);\n'
            '  if (!s) return createSession(token);\n'
            '  return verify(token) ? s : (refresh(token) ? s : null);\n}\n',
        "src/auth/middleware.ts":
            'import { validateSession, Session } from "./session";\n\n'
            'export async function authGuard(req: Request): Promise<Session | null> {\n'
            '  const h = req.headers.get("authorization") ?? "";\n'
            '  return validateSession(h.replace("Bearer ", ""));\n}\n',
        "src/report/build.ts":
            'import { validateSession } from "../auth/session";\n'
            'import { render } from "./render";\nimport { log } from "../utils/logger";\n\n'
            'export async function buildReport(userId: string) {\n'
            '  log(`building for ${userId}`);\n'
            '  const rows = await fetchRows(userId);\n  return render(rows);\n}\n\n'
            'async function fetchRows(userId: string) {\n  return [{ userId, amount: 0 }];\n}\n',
        "src/report/render.ts":
            'export function render(rows: { userId: string; amount: number }[]): string {\n'
            '  return rows.map((r) => `${r.userId},${r.amount}`).join("\\n");\n}\n',
        "src/jobs/scheduler.ts":
            'import { log } from "../utils/logger";\n\nconst queue: (() => unknown)[] = [];\n\n'
            'export function schedule(fn: () => unknown) {\n'
            '  queue.push(fn);\n  log(`queued, depth=${queue.length}`);\n}\n\n'
            'export function drain() {\n  while (queue.length) queue.shift()!();\n}\n',
        "src/utils/logger.ts": 'export function log(msg: string) {\n'
                              '  console.log(`[demo] ${msg}`);\n}\n',
        "src/utils/config.ts": 'export const cfg = { ttl: 3600, region: "ap-east-1" };\n',
        # 有些用例的对象是「一份已经写好的调研报告」（把它转语音 / 转网页）。
        # 骨架里没有这个东西时，模型会一直找到超时——实测那条被误记成 ERROR。
        "docs/缓存方案调研-完整报告.md":
            "# 会话缓存方案调研\n\n"
            "## 推荐\n\n"
            "优先 Redis；单机低并发场景可先用进程内 LRU，等出现跨实例一致性问题再迁。\n\n"
            "## 方案对比\n\n"
            "| 方案 | 一致性 | 运维成本 | 适用规模 |\n|---|---|---|---|\n"
            "| 进程内 LRU | 单实例内一致 | 极低 | 单机 |\n"
            "| Redis | 跨实例强一致 | 中 | 中大型 |\n"
            "| Memcached | 跨实例最终一致 | 中 | 只读缓存为主 |\n\n"
            "## 待验证风险\n\n"
            "- Redis 单点故障时的降级路径尚未验证\n"
            "- 缓存键的 TTL 与 token 有效期不一致会导致越权窗口\n"
            "- 冷启动雪崩未做压测\n",
    }
    for rel, body in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")


def make_arena(root: Path) -> int:
    """临时项目：把候选集收敛成「在 AICAP 里工作时」看到的那一套。

    两步：
    1. 关掉 9 个非 SSOT 本地 skill + 内置 skill —— 它们不在本仓库管辖内，
       不该参与本仓库 skill 的路由竞争。
    2. 把 SSOT 里声明了 `scope: project` 的 skill 复制进来。这类 skill 不进
       全局层（personal），只在它服务的仓库内可见；不复制的话它们不在候选集里，
       对应用例会**必然假红**——期望它触发，但它压根不在场。

    返回补进来的项目级 skill 数量。
    """
    (root / ".claude").mkdir(parents=True, exist_ok=True)
    (root / ".claude" / "settings.local.json").write_text(
        json.dumps({"disableBundledSkills": True,
                    "skillOverrides": {n: "off" for n in NON_SSOT}},
                   ensure_ascii=False, indent=2),
        encoding="utf-8")

    _write_skeleton(root)

    repo = HERE.parent
    ssot, generated = repo / ".rulesync" / "skills", repo / ".claude" / "skills"
    dest = root / ".claude" / "skills"
    n = 0
    for d in sorted(ssot.iterdir()) if ssot.is_dir() else []:
        f = d / "SKILL.md"
        if not f.is_file():
            continue
        if not re.search(r"^scope:\s*project\s*$", f.read_text(encoding="utf-8"), re.M):
            continue
        src = generated / d.name          # 用产物而非 SSOT 源：产物才是工具实际读的
        if src.is_dir():
            dest.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src, dest / d.name, dirs_exist_ok=True)
            n += 1
    return n


# 被中断时把正在跑的 claude 子进程一起带走。踩过：外部 kill 掉本脚本后，
# 它 fork 的 `claude -p` 变成孤儿继续跑，既烧订阅额度又跟下一次运行抢资源。
_child: subprocess.Popen | None = None


def _reap(signum=None, frame=None) -> None:
    global _child
    if _child is not None and _child.poll() is None:
        _child.kill()
        _child = None
    if signum is not None:
        sys.exit(130)


for _sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(_sig, _reap)
atexit.register(_reap)


def run_once(utterance: str, cwd: Path, model: str, timeout: int) -> tuple[list[str], str | None]:
    """跑一次，返回（本轮调用过的 skill 名列表, 错误原因或 None）。

    错误一律单独返回，绝不退化成「没触发」——那正是官方实现里造成假绿的地方。
    """
    global _child
    cmd = ["claude", "-p", utterance, "--output-format", "stream-json", "--verbose",
           "--model", model, "--disallowed-tools", *DENY_TOOLS.split(),
           "--no-session-persistence", "--strict-mcp-config"]
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    _child = subprocess.Popen(cmd, cwd=cwd, env=env, text=True, bufsize=1,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    fired: list[str] = []
    saw_any = False
    deadline = time.time() + timeout
    settle_until: float | None = None      # 首次命中后的观察窗口

    def note(name: str, inp: dict) -> None:
        # **只认 `Skill` 工具调用**。曾经把「Read 了某个 SKILL.md」也算触发
        # （官方实现就是这么做的），结果制造了实打实的假阳性：临时 arena 目录
        # 近乎空目录，唯一的实质文件就是补进去的项目级 skill 的 SKILL.md，
        # 于是「帮我看看这个仓库的架构」这类请求一探索目录就读到它，被记成
        # 「触发了 aicap-commit」。读一个文件和路由到一个 skill 是两回事——
        # 官方那样算是因为它测「有没有查阅」，我们测的是「路由到了谁」。
        if name == "Skill":
            s = str(inp.get("skill") or inp.get("name") or "")
            if s and s not in fired:
                fired.append(s)

    try:
        while True:
            now = time.time()
            if now > deadline or (settle_until and now > settle_until):
                break
            if _child.poll() is not None and not select.select([_child.stdout], [], [], 0)[0]:
                break
            if not select.select([_child.stdout], [], [], 0.5)[0]:
                continue
            line = _child.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            saw_any = True
            if e.get("type") != "assistant":
                continue
            for c in e.get("message", {}).get("content", []):
                if c.get("type") == "tool_use":
                    note(c.get("name", ""), c.get("input", {}))
            # 命中后只再观察一小段，收集同一轮可能的多个 Skill 调用。
            # 我们要测的是「触发了谁」，不是「它干完没有」——重型 skill
            # （survey / project-health）被触发后会真的开始跑多阶段流程，
            # 等它结束必然超时，而那个超时跟触发准确度毫无关系。
            if fired and settle_until is None:
                settle_until = time.time() + SETTLE_SECS
    finally:
        if _child.poll() is None:
            _child.kill()
        try:
            _child.communicate(timeout=5)
        except Exception:
            pass
        rc, _child = _child.returncode, None

    # 已经观察到触发就是有效结果，哪怕进程是被我们主动掐断的
    if fired:
        return fired, None
    if not saw_any:
        return [], (f"timeout>{timeout}s，且未读到任何流事件" if time.time() > deadline
                    else f"exit {rc}：无可解析输出")
    if time.time() > deadline:
        return [], f"timeout>{timeout}s（读到流事件但始终无 skill 调用）"
    return [], None                      # 正常跑完、确实没触发任何 skill


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", metavar="KEYWORD", help="只跑 description 含该关键字的用例")
    ap.add_argument("--runs", type=int, default=1, help="每条采样次数（默认 1）")
    ap.add_argument("--model", default="opus")
    ap.add_argument("--timeout", type=int, default=480,
                    help="单条上限。它覆盖的是「命中前的勘探期」——早停只在首次命中"
                         "之后生效，模型在命中前可能先读一堆代码。骨架越真实，勘探越久："
                         "给骨架补了 docs/ 之后，有两条从 300s 内通过变成 300s 超时，"
                         "放宽到 480s 又都通过。超时≠未触发，别把它当红")
    ap.add_argument("-v", action="store_true", help="打印每轮实际触发的 skill")
    args = ap.parse_args()

    cases = load_cases(args.k)
    if not cases:
        sys.exit("没有匹配的用例")

    print(f"竞技场 eval · {len(cases)} 条 × {args.runs} 次 · 模型 {args.model}")
    print("真跑 claude -p，全 SSOT skill 同场竞争，解析完整工具轨迹\n")

    hits = misses = errors = 0
    confusion: list[tuple[str, set[str], list[str]]] = []

    with tempfile.TemporaryDirectory() as td:
        arena = Path(td)
        n_proj = make_arena(arena)
        if n_proj:
            print(f"（补入 {n_proj} 个项目级 skill，否则它们不在候选集里、对应用例必然假红）\n")
        for i, c in enumerate(cases, 1):
            per_run: list[list[str]] = []
            err: str | None = None
            for _ in range(args.runs):
                fired, e = run_once(c["utterance"], arena, args.model, args.timeout)
                if e:
                    err = e
                    break
                per_run.append(fired)

            if err:
                errors += 1
                print(f"  !  [{i}/{len(cases)}] {c['description']}\n       ERROR: {err}")
                continue

            # 多次采样取「每轮都触发」的交集作为稳定触发集，避免单次抖动
            stable = set(per_run[0]).intersection(*[set(r) for r in per_run[1:]]) if per_run else set()
            union = set().union(*[set(r) for r in per_run]) if per_run else set()
            exp = c["expected"]
            ok = (stable == exp) if exp else (not union)

            if ok:
                hits += 1
                print(f"  ✓  [{i}/{len(cases)}] {c['description']}")
            else:
                misses += 1
                confusion.append((c["description"], exp, sorted(union)))
                print(f"  ✗  [{i}/{len(cases)}] {c['description']}")
                print(f"       期望 {sorted(exp) or 'NONE'} / 实际 {sorted(union) or 'NONE'}")
            if args.v:
                print(f"       各轮: {per_run}")

    print()
    if confusion:
        print("混淆矩阵（期望 → 实际）：")
        for d, exp, got in confusion:
            print(f"  · {d}\n      {sorted(exp) or 'NONE'}  →  {got or 'NONE'}")
        print()
    total = hits + misses
    print(f"{hits}/{total} 符合预期" + (f"，{errors} 条 ERROR（不计入）" if errors else ""))
    if errors:
        print("ERROR 是基础设施问题（超时/CLI 失败），不是「未触发」——不要当成通过。")
    return 1 if (misses or errors) else 0


if __name__ == "__main__":
    sys.exit(main())
