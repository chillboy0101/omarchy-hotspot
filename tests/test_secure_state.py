#!/usr/bin/python3
import importlib.util
import os
import pathlib
import stat
import tempfile

MODULE = pathlib.Path(__file__).resolve().parents[1] / "src" / "secure-state.py"


def load_module():
    spec = importlib.util.spec_from_file_location("secure_state", MODULE)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    secure_state = load_module()
    with tempfile.TemporaryDirectory() as tmp:
        state_path = pathlib.Path(tmp) / "state"
        run_path = pathlib.Path(tmp) / "run"
        state = secure_state.StateStore(state_path, run_path, expected_uid=os.geteuid())
        state.initialize()

        password = state.read_state("password", 64)
        assert 8 <= len(password) <= 63
        state.write_state("password", b"securePass42", 0o600)
        assert state.read_state("password", 64) == b"securePass42"
        assert stat.S_IMODE((state_path / "password").stat().st_mode) == 0o600

        state.write_state("ssid", b"Wis Hotspot", 0o600)
        assert state.read_state("ssid", 33) == b"Wis Hotspot"

        state.write_run("hostapd.conf", b"interface=ap0\n", 0o600)
        assert state.read_run("hostapd.conf", 8192) == b"interface=ap0\n"

        mac = secure_state.validate_mac("A8:BB:CC:11:22:33")
        aliases = secure_state.replace_tsv(b"", mac, secure_state.clean_label("Carl 📱"))
        state.write_state("device-aliases.tsv", aliases)
        assert state.read_state("device-aliases.tsv") == b"a8:bb:cc:11:22:33\tCarl \xf0\x9f\x93\xb1\n"
        aliases = secure_state.replace_tsv(aliases, mac, secure_state.clean_label("Carl 🚀"))
        state.write_state("device-aliases.tsv", aliases)
        assert state.read_state("device-aliases.tsv").decode() == "a8:bb:cc:11:22:33\tCarl 🚀\n"
        second_mac = secure_state.validate_mac("02:11:22:33:44:55")
        aliases = secure_state.replace_tsv(aliases, second_mac, secure_state.clean_label("Tablet ✨"))
        state.write_state("device-aliases.tsv", aliases)
        alias_rows = state.read_state("device-aliases.tsv").decode().splitlines()
        assert alias_rows == [
            "a8:bb:cc:11:22:33\tCarl 🚀",
            "02:11:22:33:44:55\tTablet ✨",
        ]

        blocked = secure_state.replace_tsv(b"", mac, "Carl 🚀")
        state.write_state("blocked-devices.tsv", blocked)
        assert state.read_state("blocked-devices.tsv").decode() == "a8:bb:cc:11:22:33\tCarl 🚀\n"
        state.write_state("blocked-devices.tsv", secure_state.replace_tsv(blocked, mac, None))
        assert state.read_state("blocked-devices.tsv") == b""

        metadata = secure_state.replace_tsv_row(
            b"", mac, ["10.42.0.10", "Carl📱", "android-dhcp", "01:a8:bb:cc:11:22:33"]
        )
        state.write_run("device-metadata.tsv", metadata)
        assert b"Carl\xf0\x9f\x93\xb1" in state.read_run("device-metadata.tsv")
        discovery = secure_state.replace_tsv_row(b"", mac, ["10.42.0.10", "Carl.local", "CARL", "2000000000"])
        state.write_run("device-discovery.tsv", discovery)
        assert state.read_run("device-discovery.tsv") == discovery

        try:
            secure_state.clean_label("bad\tname")
        except secure_state.SecurityError:
            pass
        else:
            raise AssertionError("control characters were accepted in a label")

        victim = pathlib.Path(tmp) / "victim"
        victim.write_text("unchanged")
        (state_path / "password").unlink()
        (state_path / "password").symlink_to(victim)
        try:
            state.write_state("password", b"anotherPass42", 0o600)
        except secure_state.SecurityError:
            pass
        else:
            raise AssertionError("symlink destination was accepted")
        assert victim.read_text() == "unchanged"

        state.close()

        unsafe_state_path = pathlib.Path(tmp) / "unsafe-state"
        unsafe_state_path.mkdir(mode=0o700)
        unsafe_state_path.chmod(0o777)
        unsafe = secure_state.StateStore(
            unsafe_state_path,
            pathlib.Path(tmp) / "unused-run",
            expected_uid=os.geteuid(),
        )
        try:
            unsafe.initialize()
        except secure_state.SecurityError:
            pass
        else:
            raise AssertionError("a group/world-writable state directory was accepted")
        finally:
            unsafe.close()
    print("secure state tests passed")


if __name__ == "__main__":
    main()
