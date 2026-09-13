#!/usr/bin/python3
import pathlib
import subprocess
import sys
import tempfile
import time

RUNNER = pathlib.Path(__file__).resolve().parents[1] / "plugin" / "run-bounded.py"


def run(*args: str, input_data: bytes = b"") -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, str(RUNNER), *args],
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )


def main() -> None:
    echoed = run("2", "1024", "/usr/bin/cat", input_data=b"secret-over-stdin")
    assert echoed.returncode == 0, echoed.stderr
    assert echoed.stdout == b"secret-over-stdin"

    timed_out = run("0.1", "1024", sys.executable, "-c", "import time; time.sleep(2)")
    assert timed_out.returncode == 124, timed_out.returncode

    with tempfile.TemporaryDirectory() as tmp:
        marker = pathlib.Path(tmp) / "escaped-child"
        child_code = f"import time,pathlib; time.sleep(0.5); pathlib.Path({str(marker)!r}).touch()"
        parent_code = (
            "import subprocess,sys,time; "
            f"subprocess.Popen([sys.executable, '-c', {child_code!r}]); "
            "time.sleep(2)"
        )
        grouped = run("0.1", "1024", sys.executable, "-c", parent_code)
        assert grouped.returncode == 124, grouped.returncode
        time.sleep(0.7)
        assert not marker.exists(), "a child escaped the timed-out process group"

    capped = run("2", "1024", sys.executable, "-c", "print('x' * 4096)")
    assert capped.returncode == 125, capped.returncode
    assert len(capped.stdout) <= 1024

    print("bounded process tests passed")


if __name__ == "__main__":
    main()
