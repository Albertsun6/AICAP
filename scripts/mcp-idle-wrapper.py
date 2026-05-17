#!/usr/bin/env python3
"""
mcp-idle-wrapper.py — MCP stdio proxy with idle timeout.

Forwards stdio between Claude Code and the wrapped MCP server.
Kills the server after MCP_IDLE_TIMEOUT seconds of inactivity (default: 1800s / 30 min).

Usage (in mcp.json):
  "command": "python3",
  "args": ["~/Desktop/AICAP/scripts/mcp-idle-wrapper.py", "npx", "-y", "some-mcp-pkg"],
  "env": { "MCP_IDLE_TIMEOUT": "1800" }
"""
import sys
import os
import time
import threading
import subprocess

TIMEOUT = int(os.environ.get("MCP_IDLE_TIMEOUT", "1800"))
cmd = sys.argv[1:]

if not cmd:
    sys.stderr.write("mcp-idle-wrapper: no command given\n")
    sys.exit(1)

last_activity = time.time()
lock = threading.Lock()


def touch():
    global last_activity
    with lock:
        last_activity = time.time()


proc = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=sys.stderr,
)


def watchdog():
    """Check every 60s; terminate if idle longer than TIMEOUT."""
    while proc.poll() is None:
        time.sleep(60)
        with lock:
            idle = time.time() - last_activity
        if idle >= TIMEOUT:
            sys.stderr.write(
                f"mcp-idle-wrapper: idle {idle:.0f}s >= {TIMEOUT}s, shutting down {cmd[0]}\n"
            )
            proc.terminate()
            return


def pipe_stdin():
    try:
        while True:
            chunk = sys.stdin.buffer.read1(4096)
            if not chunk:
                break
            touch()
            proc.stdin.write(chunk)
            proc.stdin.flush()
    except Exception:
        pass
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass


def pipe_stdout():
    try:
        while True:
            chunk = proc.stdout.read1(4096)
            if not chunk:
                break
            touch()
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    except Exception:
        pass


threading.Thread(target=watchdog, daemon=True).start()
t_in = threading.Thread(target=pipe_stdin, daemon=True)
t_out = threading.Thread(target=pipe_stdout, daemon=True)
t_in.start()
t_out.start()

proc.wait()
t_in.join(timeout=2)
t_out.join(timeout=2)
sys.exit(proc.returncode or 0)
