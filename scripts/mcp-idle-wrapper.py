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
import os
import sys
import time
import signal
import threading
import subprocess

TIMEOUT = int(os.environ.get("MCP_IDLE_TIMEOUT", "1800"))
cmd = sys.argv[1:]

if not cmd:
    sys.stderr.write("mcp-idle-wrapper: no command given\n")
    sys.exit(1)

last_activity = time.time()
lock = threading.Lock()
stop = threading.Event()
proc = None


def touch():
    global last_activity
    with lock:
        last_activity = time.time()


def shutdown(exit_code: int = 0) -> None:
    """Stop child process and I/O threads without running Py_FinalizeEx."""
    stop.set()
    if proc is not None and proc.poll() is None:
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except Exception:
            try:
                proc.kill()
                proc.wait(timeout=2)
            except Exception:
                pass
    for stream in (getattr(proc, "stdin", None), getattr(proc, "stdout", None)):
        if stream is not None:
            try:
                stream.close()
            except Exception:
                pass
    os._exit(exit_code)


def on_signal(signum, _frame):
    shutdown(128 + signum)


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)

proc = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=sys.stderr,
)


def watchdog():
    """Check every 60s; terminate if idle longer than TIMEOUT."""
    while not stop.is_set() and proc.poll() is None:
        if stop.wait(60):
            return
        with lock:
            idle = time.time() - last_activity
        if idle >= TIMEOUT:
            sys.stderr.write(
                f"mcp-idle-wrapper: idle {idle:.0f}s >= {TIMEOUT}s, shutting down {cmd[0]}\n"
            )
            shutdown(0)


def pipe_stdin():
    try:
        while not stop.is_set():
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
        while not stop.is_set():
            chunk = proc.stdout.read1(4096)
            if not chunk:
                break
            touch()
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    except Exception:
        pass


t_in = threading.Thread(target=pipe_stdin, name="mcp-stdin", daemon=True)
t_out = threading.Thread(target=pipe_stdout, name="mcp-stdout", daemon=True)
t_watch = threading.Thread(target=watchdog, name="mcp-watchdog", daemon=True)
t_in.start()
t_out.start()
t_watch.start()

exit_code = proc.wait()
stop.set()
t_in.join(timeout=2)
t_out.join(timeout=2)
# Avoid Py_FinalizeEx with live daemon threads (crashes Apple Python 3.9 on macOS).
os._exit(exit_code or 0)
