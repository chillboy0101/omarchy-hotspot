#!/usr/bin/python3
"""Symlink-safe, bounded, atomic state storage for the privileged helper."""

from __future__ import annotations

import os
import pathlib
import re
import secrets
import stat
import sys
import fcntl
from typing import Iterable

STATE_PATH = pathlib.Path("/var/lib/omarchy-hotspot")
RUN_PATH = pathlib.Path("/run/omarchy-hotspot")
MAC_RE = re.compile(r"^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")
STATE_LIMITS = {
    "password": 64,
    "ssid": 33,
    "device-aliases.tsv": 65_536,
    "blocked-devices.tsv": 65_536,
}
RUN_LIMITS = {
    "hostapd.conf": 8192,
    "device-metadata.tsv": 65_536,
    "device-discovery.tsv": 65_536,
}
SYSTEM_TARGETS = {
    "write-polkit-rule": (pathlib.Path("/etc/polkit-1/rules.d"), "50-omarchy-hotspot.rules", 16_384),
    "write-nm-config": (pathlib.Path("/etc/NetworkManager/conf.d"), "99-unmanaged-ap0.conf", 4096),
}
STATE_COMMANDS = {
    "read-password",
    "read-ssid",
    "read-blocked",
    "write-password",
    "write-ssid",
    "set-alias",
    "block",
    "unblock",
}
RUNTIME_COMMANDS = {
    "write-hostapd",
    "upsert-metadata",
    "upsert-discovery",
    "delete-metadata",
    "delete-discovery",
}


class SecurityError(RuntimeError):
    pass


def read_stdin_bounded(limit: int) -> bytes:
    data = sys.stdin.buffer.read(limit + 1)
    if len(data) > limit:
        raise SecurityError("input exceeds the allowed size")
    return data


class SafeDirectory:
    def __init__(
        self,
        path: pathlib.Path,
        expected_uid: int,
        mode: int = 0o700,
        legacy_uids: Iterable[int] = (),
        lock: bool = False,
    ):
        self.path = path
        self.expected_uid = expected_uid
        self.expected_gid = 0 if expected_uid == 0 else os.getegid()
        self.mode = mode
        self.legacy_uids = set(legacy_uids)
        self.lock = lock
        self.fd = -1
        self.lock_fd = -1

    def open(self) -> None:
        parent = os.lstat(self.path.parent)
        if not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode):
            raise SecurityError(f"unsafe parent directory: {self.path.parent}")
        if parent.st_uid != self.expected_uid or parent.st_mode & 0o022:
            raise SecurityError(f"unsafe parent ownership or mode: {self.path.parent}")
        try:
            info = os.lstat(self.path)
        except FileNotFoundError:
            os.mkdir(self.path, self.mode)
            info = os.lstat(self.path)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise SecurityError(f"unsafe directory: {self.path}")
        if info.st_uid != self.expected_uid and info.st_uid not in self.legacy_uids:
            raise SecurityError(f"unexpected owner for {self.path}")
        if info.st_mode & 0o022:
            raise SecurityError(f"unsafe mode for {self.path}")
        self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
        opened = os.fstat(self.fd)
        if opened.st_dev != info.st_dev or opened.st_ino != info.st_ino:
            raise SecurityError(f"directory changed while opening: {self.path}")
        os.fchown(self.fd, self.expected_uid, self.expected_gid)
        os.fchmod(self.fd, self.mode)
        if self.lock:
            self.lock_fd = os.open(
                ".omarchy-hotspot.lock",
                os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=self.fd,
            )
            lock_info = os.fstat(self.lock_fd)
            if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_nlink != 1:
                raise SecurityError(f"unsafe lock file in {self.path}")
            if lock_info.st_uid != self.expected_uid or lock_info.st_mode & 0o022:
                raise SecurityError(f"unsafe lock ownership or mode in {self.path}")
            os.fchmod(self.lock_fd, 0o600)
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX)

    def close(self) -> None:
        if self.lock_fd >= 0:
            os.close(self.lock_fd)
            self.lock_fd = -1
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def _existing(self, name: str) -> os.stat_result | None:
        try:
            info = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise SecurityError(f"unsafe state file: {name}")
        return info

    def read(self, name: str, limit: int, allowed_uids: Iterable[int] | None = None) -> bytes:
        info = self._existing(name)
        if info is None:
            raise FileNotFoundError(name)
        owners = set(allowed_uids if allowed_uids is not None else (self.expected_uid,))
        if info.st_uid not in owners or info.st_mode & 0o022:
            raise SecurityError(f"unsafe ownership or mode for {name}")
        if info.st_size > limit:
            raise SecurityError(f"state file too large: {name}")
        fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=self.fd)
        try:
            opened = os.fstat(fd)
            if opened.st_dev != info.st_dev or opened.st_ino != info.st_ino:
                raise SecurityError(f"state file changed while opening: {name}")
            data = bytearray()
            while len(data) <= limit:
                chunk = os.read(fd, min(4096, limit + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            if len(data) > limit:
                raise SecurityError(f"state file too large: {name}")
            return bytes(data)
        finally:
            os.close(fd)

    def write(
        self,
        name: str,
        data: bytes,
        mode: int,
        limit: int,
        allowed_existing_uids: Iterable[int] | None = None,
    ) -> None:
        if len(data) > limit:
            raise SecurityError(f"state value too large: {name}")
        existing = self._existing(name)
        allowed_owners = set(allowed_existing_uids or (self.expected_uid,))
        if existing is not None:
            if existing.st_uid not in allowed_owners:
                raise SecurityError(f"unexpected owner for {name}")
            if existing.st_mode & 0o022:
                raise SecurityError(f"unsafe mode for {name}")
        temporary = f".{name}.{secrets.token_hex(12)}"
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            mode,
            dir_fd=self.fd,
        )
        try:
            os.fchmod(fd, mode)
            os.fchown(fd, self.expected_uid, self.expected_gid)
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        except BaseException:
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except FileNotFoundError:
                pass
            raise
        finally:
            os.close(fd)
        os.rename(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
        os.fsync(self.fd)


class StateStore:
    def __init__(
        self,
        state_path: pathlib.Path = STATE_PATH,
        run_path: pathlib.Path = RUN_PATH,
        expected_uid: int = 0,
        legacy_uid: int | None = None,
    ):
        self.expected_uid = expected_uid
        self.legacy_uid = legacy_uid
        legacy_owners = {uid for uid in (legacy_uid, 65534) if uid is not None}
        self.state = SafeDirectory(state_path, expected_uid, legacy_uids=legacy_owners, lock=True)
        self.runtime = SafeDirectory(run_path, expected_uid, legacy_uids=legacy_owners, lock=True)

    def open_state(self) -> None:
        self.state.open()

    def open_runtime(self) -> None:
        self.runtime.open()

    def open(self) -> None:
        self.open_state()
        self.open_runtime()

    def initialize(self) -> None:
        self.open()
        legacy_owners = {self.expected_uid}
        if self.legacy_uid is not None:
            legacy_owners.add(self.legacy_uid)
        legacy_owners.update(self.state.legacy_uids)

        defaults = {
            "password": "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789") for _ in range(14)).encode(),
            "ssid": b"OmarchyHotspot",
            "device-aliases.tsv": b"",
            "blocked-devices.tsv": b"",
        }
        for name, default in defaults.items():
            limit = STATE_LIMITS[name]
            try:
                value = self.state.read(name, limit, legacy_owners)
            except FileNotFoundError:
                value = default
            if name == "password":
                validate_password(value)
            elif name == "ssid":
                validate_ssid(value)
            self.state.write(name, value, 0o600, limit, legacy_owners)

        runtime_owners = {self.expected_uid, *self.runtime.legacy_uids}
        for name, limit in RUN_LIMITS.items():
            try:
                value = self.runtime.read(name, limit, runtime_owners)
            except FileNotFoundError:
                continue
            self.runtime.write(name, value, 0o600, limit, runtime_owners)

    def close(self) -> None:
        self.runtime.close()
        self.state.close()

    def read_state(self, name: str, limit: int | None = None) -> bytes:
        allowed = STATE_LIMITS.get(name)
        if allowed is None:
            raise SecurityError("state file is not allowlisted")
        return self.state.read(name, min(limit or allowed, allowed))

    def write_state(self, name: str, data: bytes, mode: int = 0o600) -> None:
        limit = STATE_LIMITS.get(name)
        if limit is None:
            raise SecurityError("state file is not allowlisted")
        self.state.write(name, data, mode, limit)

    def read_run(self, name: str, limit: int | None = None) -> bytes:
        allowed = RUN_LIMITS.get(name)
        if allowed is None:
            raise SecurityError("runtime file is not allowlisted")
        return self.runtime.read(name, min(limit or allowed, allowed))

    def write_run(self, name: str, data: bytes, mode: int = 0o600) -> None:
        limit = RUN_LIMITS.get(name)
        if limit is None:
            raise SecurityError("runtime file is not allowlisted")
        self.runtime.write(name, data, mode, limit)


def validate_password(value: bytes) -> None:
    if not 8 <= len(value) <= 63 or any(byte < 0x20 or byte > 0x7E for byte in value):
        raise SecurityError("password must be 8-63 printable ASCII characters")


def validate_ssid(value: bytes) -> None:
    if not 1 <= len(value) <= 32 or any(byte < 0x20 or byte == 0x7F for byte in value):
        raise SecurityError("SSID must be 1-32 printable bytes")


def validate_mac(value: str) -> str:
    if not MAC_RE.fullmatch(value):
        raise SecurityError("invalid device address")
    return value.lower()


def clean_label(value: str) -> str:
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value) or "\t" in value:
        raise SecurityError("device name contains control characters")
    if len(value) > 48:
        raise SecurityError("device name must be 48 characters or fewer")
    return value


def replace_tsv(data: bytes, mac: str, label: str | None) -> bytes:
    rows: list[str] = []
    for raw in data.decode("utf-8", "strict").splitlines():
        fields = raw.split("\t", 1)
        if fields and fields[0].lower() != mac:
            rows.append(raw)
    if label is not None:
        rows.append(f"{mac}\t{label}")
    return (("\n".join(rows) + "\n") if rows else "").encode("utf-8")


def clean_tsv_field(value: str, maximum: int = 255) -> str:
    if len(value) > maximum or "\t" in value or any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        raise SecurityError("invalid metadata field")
    return value


def replace_tsv_row(data: bytes, mac: str, fields: list[str] | None) -> bytes:
    rows = [
        raw
        for raw in data.decode("utf-8", "strict").splitlines()
        if raw.split("\t", 1)[0].lower() != mac
    ]
    if fields is not None:
        rows.append("\t".join([mac, *fields]))
    return (("\n".join(rows) + "\n") if rows else "").encode("utf-8")


def caller_uid() -> int | None:
    raw = os.environ.get("PKEXEC_UID") or os.environ.get("SUDO_UID")
    if raw and raw.isdigit():
        return int(raw)
    return None


def main(argv: list[str]) -> int:
    if os.geteuid() != 0:
        raise SecurityError("secure state helper must run as root")
    if len(argv) != 2:
        raise SecurityError("usage: secure-state.py COMMAND")
    command = argv[1]
    if command in SYSTEM_TARGETS:
        directory_path, name, limit = SYSTEM_TARGETS[command]
        directory = SafeDirectory(directory_path, 0, 0o755)
        try:
            directory.open()
            value = read_stdin_bounded(limit)
            if b"\x00" in value:
                raise SecurityError("system configuration contains NUL")
            directory.write(name, value, 0o644, limit)
            return 0
        finally:
            directory.close()

    store = StateStore(legacy_uid=caller_uid())
    try:
        if command == "init":
            store.initialize()
            return 0
        if command in STATE_COMMANDS:
            store.open_state()
        elif command in RUNTIME_COMMANDS:
            store.open_runtime()
        else:
            raise SecurityError("unknown secure state command")
        if command == "read-password":
            sys.stdout.buffer.write(store.read_state("password"))
        elif command == "read-ssid":
            sys.stdout.buffer.write(store.read_state("ssid"))
        elif command == "read-blocked":
            sys.stdout.buffer.write(store.read_state("blocked-devices.tsv"))
        elif command == "write-password":
            value = read_stdin_bounded(64).rstrip(b"\n")
            validate_password(value)
            store.write_state("password", value)
        elif command == "write-ssid":
            value = read_stdin_bounded(33).rstrip(b"\n")
            validate_ssid(value)
            store.write_state("ssid", value)
        elif command == "write-hostapd":
            value = read_stdin_bounded(RUN_LIMITS["hostapd.conf"])
            if b"\x00" in value:
                raise SecurityError("hostapd configuration contains NUL")
            store.write_run("hostapd.conf", value)
        elif command in ("upsert-metadata", "upsert-discovery"):
            lines = read_stdin_bounded(2048).decode("utf-8", "strict").splitlines()
            expected = 5
            if len(lines) != expected:
                raise SecurityError("invalid metadata record")
            mac = validate_mac(lines[0])
            fields = [clean_tsv_field(value) for value in lines[1:]]
            name = "device-metadata.tsv" if command == "upsert-metadata" else "device-discovery.tsv"
            try:
                old = store.read_run(name)
            except FileNotFoundError:
                old = b""
            store.write_run(name, replace_tsv_row(old, mac, fields))
        elif command in ("delete-metadata", "delete-discovery"):
            mac = validate_mac(read_stdin_bounded(32).decode("ascii", "strict").strip())
            name = "device-metadata.tsv" if command == "delete-metadata" else "device-discovery.tsv"
            try:
                old = store.read_run(name)
            except FileNotFoundError:
                old = b""
            store.write_run(name, replace_tsv_row(old, mac, None))
        elif command == "set-alias":
            lines = read_stdin_bounded(512).decode("utf-8", "strict").splitlines()
            if not lines:
                raise SecurityError("missing device address")
            mac = validate_mac(lines[0])
            label = clean_label(lines[1] if len(lines) > 1 else "")
            old = store.read_state("device-aliases.tsv")
            store.write_state("device-aliases.tsv", replace_tsv(old, mac, label or None))
        elif command == "block":
            lines = read_stdin_bounded(512).decode("utf-8", "strict").splitlines()
            if not lines:
                raise SecurityError("missing device address")
            mac = validate_mac(lines[0])
            label = clean_label(lines[1] if len(lines) > 1 else "Unknown device") or "Unknown device"
            old = store.read_state("blocked-devices.tsv")
            store.write_state("blocked-devices.tsv", replace_tsv(old, mac, label))
        elif command == "unblock":
            mac = validate_mac(read_stdin_bounded(32).decode("ascii", "strict").strip())
            old = store.read_state("blocked-devices.tsv")
            store.write_state("blocked-devices.tsv", replace_tsv(old, mac, None))
        return 0
    finally:
        store.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (SecurityError, UnicodeError, OSError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
