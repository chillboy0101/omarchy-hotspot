#!/usr/bin/python3
"""Run one process with a wall-clock deadline and a live combined-output cap."""

from __future__ import annotations

import os
import selectors
import signal
import subprocess
import sys
import time

TIMEOUT_EXIT = 124
OUTPUT_LIMIT_EXIT = 125
MAX_TIMEOUT = 30.0
MAX_OUTPUT = 262_144


def fail(message: str, code: int = 2) -> int:
    print(message, file=sys.stderr)
    return code


def terminate_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=0.25)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        return fail("usage: run-bounded.py TIMEOUT_SECONDS MAX_OUTPUT_BYTES /absolute/program [args...]")
    try:
        timeout = float(argv[1])
        output_limit = int(argv[2])
    except ValueError:
        return fail("invalid timeout or output limit")
    if not (0.05 <= timeout <= MAX_TIMEOUT):
        return fail("timeout is outside the allowed range")
    if not (256 <= output_limit <= MAX_OUTPUT):
        return fail("output limit is outside the allowed range")

    command = argv[3:]
    if not os.path.isabs(command[0]) or "\x00" in command[0]:
        return fail("program must be an absolute path")

    child_env = {
        "PATH": "/usr/bin:/usr/sbin",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
    }
    for name in ("WAYLAND_DISPLAY", "DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"):
        value = os.environ.get(name)
        if value:
            child_env[name] = value

    process = subprocess.Popen(
        command,
        stdin=None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        env=child_env,
    )
    assert process.stdout is not None and process.stderr is not None

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, sys.stdout.buffer)
    selector.register(process.stderr, selectors.EVENT_READ, sys.stderr.buffer)
    deadline = time.monotonic() + timeout
    emitted = 0
    result_override: int | None = None

    def stop_from_signal(_signum: int, _frame: object) -> None:
        terminate_group(process)

    signal.signal(signal.SIGTERM, stop_from_signal)
    signal.signal(signal.SIGINT, stop_from_signal)

    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                result_override = TIMEOUT_EXIT
                terminate_group(process)
                break
            for key, _mask in selector.select(min(0.1, remaining)):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                allowed = output_limit - emitted
                if allowed > 0:
                    visible = chunk[:allowed]
                    key.data.write(visible)
                    key.data.flush()
                    emitted += len(visible)
                if len(chunk) > allowed:
                    result_override = OUTPUT_LIMIT_EXIT
                    terminate_group(process)
                    break
            if result_override is not None:
                break
        if result_override is None:
            remaining = deadline - time.monotonic()
            try:
                process.wait(timeout=max(0.0, remaining))
            except subprocess.TimeoutExpired:
                result_override = TIMEOUT_EXIT
                terminate_group(process)
    finally:
        selector.close()
        if process.poll() is None:
            terminate_group(process)
        process.wait()

    return result_override if result_override is not None else process.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
