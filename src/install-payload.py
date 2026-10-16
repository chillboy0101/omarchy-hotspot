#!/usr/bin/python3
"""Digest-verified installer for the Omarchy Hotspot system helper.

Stage (unprivileged): open every allowlisted payload file once through
no-follow descriptors, verify it against the committed payload.sha256
manifest, and keep the verified bytes in memory.

Handoff: pkexec authorizes a fixed bootstrap whose argv carries the SHA-256 of
this installer and of the payload manifest. The verified bytes travel to the
privileged process over a pipe, so root never opens a file in the
user-writable checkout and a later pathname or file swap cannot change what
gets installed.

Install (root): re-verify the installer, manifest, and every payload digest,
then write each file through retained root-owned directory descriptors using
exclusive temporary files, fsync, and atomic renames.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import pwd
import re
import secrets
import stat
import subprocess
import sys

MANIFEST_NAME = "payload.sha256"
INSTALLER_PATH = "src/install-payload.py"
MANIFEST_LIMIT = 4096
FILE_LIMIT = 262_144
FRAME_HEADER_LIMIT = 16
POLKIT_RULE_PATH = "config/50-omarchy-hotspot.rules"
NM_CONFIG_PATH = "config/99-unmanaged-ap0.conf"
STATE_TOOL = "/usr/local/lib/omarchy-hotspot-secure-state"
MANIFEST_LINE_RE = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
USER_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}\$?$")
PRIVILEGED_ENV = {"PATH": "/nonexistent", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}

# Every file the installer reads. Installed files list their destination
# directory (path components below /), file name, and mode; the rest are
# installer inputs only.
PAYLOAD: dict[str, tuple[tuple[str, ...], str, int] | None] = {
    POLKIT_RULE_PATH: None,
    NM_CONFIG_PATH: None,
    INSTALLER_PATH: None,
    "src/secure-state.py": (("usr", "local", "lib"), "omarchy-hotspot-secure-state", 0o755),
    "src/device-identification.sh": (("usr", "local", "lib"), "omarchy-hotspot-device-identification.sh", 0o644),
    "src/lease-event.sh": (("usr", "local", "lib"), "omarchy-hotspot-lease-event.sh", 0o755),
    "src/discover-device.sh": (("usr", "local", "lib"), "omarchy-hotspot-discover-device.sh", 0o755),
    # The polkit-authorized entry point goes last, after its support files.
    "src/omarchy-hotspot-helper": (("usr", "local", "bin"), "omarchy-hotspot-helper", 0o755),
}

# Executed by root via pkexec. It reads the installer from stdin, refuses it
# unless its SHA-256 matches the digest fixed in the authorized argv, and only
# then runs it with the manifest digest from that same argv.
BOOTSTRAP = """\
import hashlib, sys
s = sys.stdin.buffer
h = s.readline(16)
n = int(h) if h.endswith(b"\\n") and h[:-1].isdigit() else -1
if not 0 < n <= 262144:
    raise SystemExit("invalid installer frame")
c = s.read(n)
if len(c) != n or hashlib.sha256(c).hexdigest() != sys.argv[1]:
    raise SystemExit("installer digest mismatch")
sys.argv = ["omarchy-hotspot-install", "--privileged", sys.argv[2]]
exec(compile(c, "omarchy-hotspot-install", "exec"), {"__name__": "__main__"})
"""


class SecurityError(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_manifest(manifest: bytes) -> list[tuple[str, str]]:
    if len(manifest) > MANIFEST_LIMIT:
        raise SecurityError("payload manifest is too large")
    entries: list[tuple[str, str]] = []
    for line in manifest.decode("ascii", "strict").splitlines():
        match = MANIFEST_LINE_RE.fullmatch(line)
        if not match:
            raise SecurityError(f"malformed payload manifest line: {line!r}")
        entries.append((match.group(1), match.group(2)))
    paths = [path for _, path in entries]
    if sorted(paths) != sorted(PAYLOAD) or len(set(paths)) != len(paths):
        raise SecurityError("payload manifest does not list exactly the allowlisted files")
    return entries


def read_bounded(fd: int, limit: int, label: str) -> bytes:
    data = bytearray()
    while len(data) <= limit:
        chunk = os.read(fd, min(65_536, limit + 1 - len(data)))
        if not chunk:
            break
        data.extend(chunk)
    if len(data) > limit:
        raise SecurityError(f"{label} is too large")
    return bytes(data)


def read_relative(directory_fd: int, relative: str, limit: int) -> bytes:
    parts = relative.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise SecurityError(f"unsafe payload path: {relative}")
    opened: list[int] = []
    try:
        current = directory_fd
        for part in parts[:-1]:
            current = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current)
            opened.append(current)
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=current)
        opened.append(fd)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SecurityError(f"payload file is not a regular file: {relative}")
        if info.st_size > limit:
            raise SecurityError(f"payload file is too large: {relative}")
        return read_bounded(fd, limit, relative)
    except OSError as error:
        raise SecurityError(f"cannot safely read payload file {relative}: {error.strerror}") from error
    finally:
        for fd in reversed(opened):
            os.close(fd)


def stage(repo: pathlib.Path) -> tuple[bytes, list[tuple[str, str]], dict[str, bytes]]:
    """Read and verify the allowlisted payload without privileges."""
    repo_fd = os.open(repo, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        manifest = read_relative(repo_fd, MANIFEST_NAME, MANIFEST_LIMIT)
        entries = parse_manifest(manifest)
        files: dict[str, bytes] = {}
        for digest, path in entries:
            data = read_relative(repo_fd, path, FILE_LIMIT)
            if sha256(data) != digest:
                raise SecurityError(f"{path} does not match {MANIFEST_NAME}; refusing to install")
            files[path] = data
        return manifest, entries, files
    finally:
        os.close(repo_fd)


def frame(data: bytes) -> bytes:
    return b"%d\n" % len(data) + data


def encode_stream(installer: bytes, manifest: bytes, entries: list[tuple[str, str]], files: dict[str, bytes]) -> bytes:
    return frame(installer) + frame(manifest) + b"".join(frame(files[path]) for _, path in entries)


def read_frame(stream, limit: int, label: str) -> bytes:
    header = stream.readline(FRAME_HEADER_LIMIT)
    if not header.endswith(b"\n") or not header[:-1].isdigit():
        raise SecurityError(f"malformed payload stream before {label}")
    size = int(header)
    if size > limit:
        raise SecurityError(f"{label} is too large")
    data = stream.read(size)
    if len(data) != size:
        raise SecurityError(f"truncated payload stream at {label}")
    return data


def read_stream(stream, manifest_digest: str) -> tuple[list[tuple[str, str]], dict[str, bytes]]:
    """Read the payload that follows the installer frame and verify every digest."""
    if not DIGEST_RE.fullmatch(manifest_digest):
        raise SecurityError("invalid manifest digest")
    manifest = read_frame(stream, MANIFEST_LIMIT, MANIFEST_NAME)
    if sha256(manifest) != manifest_digest:
        raise SecurityError("payload manifest does not match the authorized digest")
    entries = parse_manifest(manifest)
    files: dict[str, bytes] = {}
    for digest, path in entries:
        data = read_frame(stream, FILE_LIMIT, path)
        if sha256(data) != digest:
            raise SecurityError(f"{path} does not match the authorized manifest")
        files[path] = data
    if stream.read(1):
        raise SecurityError("unexpected data after the payload")
    return entries, files


def render_polkit_rule(template: bytes, user: str) -> bytes:
    # The name lands inside a JavaScript string literal, so accept only
    # ordinary account-name characters.
    if not USER_RE.fullmatch(user):
        raise SecurityError(f"refusing to write a polkit rule for unusual user name {user!r}")
    if template.count(b"__USER__") != 1:
        raise SecurityError("polkit rule template must contain exactly one __USER__ placeholder")
    return template.replace(b"__USER__", user.encode("ascii"))


class SystemTree:
    """Root-owned directory walk and atomic file replacement below one root."""

    def __init__(self, root: str = "/", uid: int = 0, gid: int = 0):
        self.root = root
        self.uid = uid
        self.gid = gid

    def _verify_directory(self, fd: int, label: str) -> None:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode):
            raise SecurityError(f"not a directory: {label}")
        if info.st_uid != self.uid or info.st_mode & 0o022:
            raise SecurityError(f"unsafe ownership or mode for {label}")

    def open_directory(self, components: tuple[str, ...]) -> int:
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        label = self.root
        try:
            self._verify_directory(fd, label)
            for name in components:
                label = f"{label.rstrip('/')}/{name}"
                try:
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                except FileNotFoundError:
                    os.mkdir(name, 0o755, dir_fd=fd)
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
                os.close(fd)
                fd = child
                self._verify_directory(fd, label)
            return fd
        except OSError as error:
            os.close(fd)
            raise SecurityError(f"cannot safely open {label}: {error.strerror}") from error
        except BaseException:
            os.close(fd)
            raise

    def install(self, directory_fd: int, name: str, data: bytes, mode: int) -> None:
        try:
            existing = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and not stat.S_ISREG(existing.st_mode):
            raise SecurityError(f"refusing to replace non-regular file {name}")
        temporary = f".{name}.{secrets.token_hex(12)}"
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=directory_fd,
        )
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fchown(fd, self.uid, self.gid)
            os.fchmod(fd, mode)
            os.fsync(fd)
        except BaseException:
            os.close(fd)
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            raise
        os.close(fd)
        os.rename(temporary, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)

    def install_payload(self, entries: list[tuple[str, str]], files: dict[str, bytes]) -> None:
        order = [path for path in PAYLOAD if PAYLOAD[path] is not None]
        if not set(order) <= {path for _, path in entries}:
            raise SecurityError("payload is missing an installable file")
        for path in order:
            components, name, mode = PAYLOAD[path]
            directory_fd = self.open_directory(components)
            try:
                self.install(directory_fd, name, files[path], mode)
            finally:
                os.close(directory_fd)


def caller_uid() -> int:
    for name in ("PKEXEC_UID", "SUDO_UID"):
        raw = os.environ.get(name, "")
        if raw.isdigit():
            return int(raw)
    raise SecurityError("run ./install.sh as the desktop user who will use the hotspot")


def run(argv: list[str], uid: int, data: bytes | None = None, check: bool = True, path: str | None = None) -> None:
    env = dict(PRIVILEGED_ENV, PKEXEC_UID=str(uid))
    if path is not None:
        env["PATH"] = path
    subprocess.run(argv, input=data, env=env, check=check, close_fds=True)


def privileged(manifest_digest: str) -> int:
    if os.geteuid() != 0:
        raise SecurityError("the privileged install stage must run as root")
    uid = caller_uid()
    if uid == 0:
        raise SecurityError("run ./install.sh as the desktop user who will use the hotspot, not as root")
    user = pwd.getpwuid(uid).pw_name
    os.environ.clear()
    os.environ.update(PRIVILEGED_ENV)
    os.umask(0o077)

    entries, files = read_stream(sys.stdin.buffer, manifest_digest)
    rule = render_polkit_rule(files[POLKIT_RULE_PATH], user)
    print(f"==> Payload verified as root ({len(entries)} files, manifest sha256 {manifest_digest})")

    print("==> Installing packages (hostapd, dnsmasq)", flush=True)
    # Package scriptlets and hooks need a command search path; give pacman a
    # fixed root-owned one instead of anything inherited from the caller.
    run(["/usr/bin/pacman", "-S", "--noconfirm", "--needed", "hostapd", "dnsmasq"], uid, path="/usr/bin")

    print("==> Installing helper to /usr/local/bin", flush=True)
    SystemTree().install_payload(entries, files)
    run(["/usr/bin/python3", "-I", "-S", STATE_TOOL, "init"], uid)

    print("==> Installing polkit rule (passwordless pkexec for the helper)", flush=True)
    run(["/usr/bin/python3", "-I", "-S", STATE_TOOL, "write-polkit-rule"], uid, rule)

    print("==> Telling NetworkManager to leave ap0 alone", flush=True)
    run(["/usr/bin/python3", "-I", "-S", STATE_TOOL, "write-nm-config"], uid, files[NM_CONFIG_PATH])
    run(["/usr/bin/nmcli", "general", "reload"], uid, check=False)

    print()
    print("Done! Now install the widget with:")
    print("  omarchy plugin add https://github.com/chillboy0101/omarchy-hotspot")
    print("  omarchy plugin enable io.github.chillboy0101.omarchy-hotspot --section right")
    return 0


def unprivileged(repo: pathlib.Path) -> int:
    manifest, entries, files = stage(repo)
    installer = files[INSTALLER_PATH]
    installer_digest = sha256(installer)
    manifest_digest = sha256(manifest)
    print(f"==> Verified {len(entries)} payload files against {MANIFEST_NAME}")
    print(f"    manifest sha256 {manifest_digest}")

    command = ["/usr/bin/python3", "-I", "-S", "-c", BOOTSTRAP, installer_digest, manifest_digest]
    env = {"PATH": "/usr/bin", "LANG": "C.UTF-8"}
    if os.geteuid() == 0:
        env["SUDO_UID"] = os.environ.get("SUDO_UID", "")
    else:
        command.insert(0, "/usr/bin/pkexec")
    process = subprocess.Popen(command, stdin=subprocess.PIPE, env=env, close_fds=True)
    try:
        process.stdin.write(encode_stream(installer, manifest, entries, files))
        process.stdin.close()
    except BrokenPipeError:
        pass
    status = process.wait()
    if status in (126, 127) and os.geteuid() != 0:
        print("Authorization was cancelled or denied; nothing was installed.", file=sys.stderr)
    return status


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--privileged":
        return privileged(argv[2])
    if len(argv) == 3 and argv[1] == "--stage":
        return unprivileged(pathlib.Path(argv[2]))
    raise SecurityError("usage: install-payload.py --stage REPO_DIR")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (SecurityError, UnicodeError, OSError, subprocess.CalledProcessError) as error:
        print(f"install failed: {error}", file=sys.stderr)
        raise SystemExit(1)
