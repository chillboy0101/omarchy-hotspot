#!/usr/bin/python3
"""Copy one bounded secret from stdin without exposing it in argv."""

import os
import subprocess
import sys


def main() -> int:
    secret = sys.stdin.buffer.readline(65)
    if not secret.endswith(b"\n") or len(secret) > 64:
        print("invalid secret input", file=sys.stderr)
        return 2
    secret = secret[:-1]
    environment = {
        "PATH": "/usr/bin:/usr/sbin",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
    }
    for name in ("WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    try:
        result = subprocess.run(
            ["/usr/bin/wl-copy"],
            input=secret,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=2,
            env=environment,
            check=False,
        )
    except subprocess.TimeoutExpired:
        print("clipboard command timed out", file=sys.stderr)
        return 124
    if result.returncode != 0:
        sys.stderr.buffer.write(result.stderr[:1024])
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
