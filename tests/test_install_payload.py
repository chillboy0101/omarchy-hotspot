#!/usr/bin/python3
import importlib.util
import io
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
MODULE = REPO / "src" / "install-payload.py"


def load_module():
    spec = importlib.util.spec_from_file_location("install_payload", MODULE)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect_security_error(module, function, *args):
    try:
        function(*args)
    except module.SecurityError:
        return
    raise AssertionError(f"{function.__name__} accepted unsafe input")


def copy_payload(module, destination: pathlib.Path) -> None:
    for relative in [module.MANIFEST_NAME, *module.PAYLOAD]:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / relative, target)


def run_bootstrap(module, installer_digest: str, manifest_digest: str, stream: bytes):
    return subprocess.run(
        ["/usr/bin/python3", "-I", "-S", "-c", module.BOOTSTRAP, installer_digest, manifest_digest],
        input=stream,
        capture_output=True,
        env={"PATH": "/usr/bin"},
        check=False,
    )


def main() -> None:
    module = load_module()

    # The committed manifest covers exactly the allowlist and matches the tree.
    manifest, entries, files = module.stage(REPO)
    assert sorted(path for _, path in entries) == sorted(module.PAYLOAD)
    assert all(module.sha256(files[path]) == digest for digest, path in entries)

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)

        # A modified payload file is refused before elevation.
        tampered = root / "tampered"
        copy_payload(module, tampered)
        with open(tampered / "src" / "omarchy-hotspot-helper", "ab") as handle:
            handle.write(b"\n# injected\n")
        expect_security_error(module, module.stage, tampered)

        # A symlinked payload file is refused even when its target matches.
        linked = root / "linked"
        copy_payload(module, linked)
        helper = linked / "src" / "omarchy-hotspot-helper"
        helper.unlink()
        helper.symlink_to(REPO / "src" / "omarchy-hotspot-helper")
        expect_security_error(module, module.stage, linked)

        # A symlinked payload directory is refused.
        linked_dir = root / "linked-dir"
        copy_payload(module, linked_dir)
        shutil.rmtree(linked_dir / "config")
        (linked_dir / "config").symlink_to(REPO / "config")
        expect_security_error(module, module.stage, linked_dir)

        # The manifest must list exactly the allowlisted files.
        lines = manifest.decode().splitlines()
        expect_security_error(module, module.parse_manifest, ("\n".join(lines[1:]) + "\n").encode())
        extra = lines + [f"{'0' * 64}  src/extra.sh"]
        expect_security_error(module, module.parse_manifest, ("\n".join(extra) + "\n").encode())
        expect_security_error(module, module.parse_manifest, b"not-a-digest  install.sh\n")

        # The privileged reader re-verifies every digest and rejects trailing data.
        installer = files[module.INSTALLER_PATH]
        stream = module.encode_stream(installer, manifest, entries, files)
        body = stream[len(module.frame(installer)):]
        manifest_digest = module.sha256(manifest)
        read_entries, read_files = module.read_stream(io.BytesIO(body), manifest_digest)
        assert read_entries == entries and read_files == files
        expect_security_error(module, module.read_stream, io.BytesIO(body + b"x"), manifest_digest)
        expect_security_error(module, module.read_stream, io.BytesIO(body[:-1]), manifest_digest)
        expect_security_error(module, module.read_stream, io.BytesIO(body), "0" * 64)
        swapped = dict(files)
        swapped["src/omarchy-hotspot-helper"] = files["src/omarchy-hotspot-helper"] + b"\n"
        swapped_body = module.encode_stream(installer, manifest, entries, swapped)[len(module.frame(installer)):]
        expect_security_error(module, module.read_stream, io.BytesIO(swapped_body), manifest_digest)

        # The root bootstrap refuses an installer whose digest differs from argv,
        # and runs a matching one (which then insists on real root).
        installer_digest = module.sha256(installer)
        refused = run_bootstrap(module, "0" * 64, manifest_digest, stream)
        assert refused.returncode != 0 and b"installer digest mismatch" in refused.stderr
        if os.geteuid() != 0:
            accepted = run_bootstrap(module, installer_digest, manifest_digest, stream)
            assert accepted.returncode == 1
            assert b"must run as root" in accepted.stderr, accepted.stderr

        # Installation writes through verified directories with exact modes.
        target = root / "target"
        (target / "usr" / "local").mkdir(parents=True)
        os.chmod(target, 0o755)
        tree = module.SystemTree(str(target), os.geteuid(), os.getegid())
        tree.install_payload(entries, files)
        for path, destination in module.PAYLOAD.items():
            if destination is None:
                continue
            components, name, mode = destination
            installed = target.joinpath(*components, name)
            assert installed.read_bytes() == files[path]
            assert stat.S_IMODE(installed.stat().st_mode) == mode
        leftovers = [entry.name for entry in (target / "usr" / "local" / "lib").iterdir() if entry.name.startswith(".")]
        assert leftovers == [], leftovers

        # Reinstalling over existing files is atomic and keeps the same result.
        tree.install_payload(entries, files)

        # A symlinked or group-writable destination directory is refused.
        hostile = root / "hostile"
        (hostile / "usr" / "local").mkdir(parents=True)
        os.chmod(hostile, 0o755)
        (hostile / "elsewhere").mkdir()
        (hostile / "usr" / "local" / "lib").symlink_to(hostile / "elsewhere")
        expect_security_error(module, module.SystemTree(str(hostile), os.geteuid(), os.getegid()).install_payload, entries, files)
        assert not any((hostile / "elsewhere").iterdir())

        writable = root / "writable"
        (writable / "usr" / "local").mkdir(parents=True)
        os.chmod(writable, 0o755)
        os.chmod(writable / "usr" / "local", 0o775)
        expect_security_error(module, module.SystemTree(str(writable), os.geteuid(), os.getegid()).install_payload, entries, files)

        # A non-regular destination is never replaced.
        blocked = root / "blocked"
        (blocked / "usr" / "local" / "lib" / "omarchy-hotspot-secure-state").mkdir(parents=True)
        os.chmod(blocked, 0o755)
        expect_security_error(module, module.SystemTree(str(blocked), os.geteuid(), os.getegid()).install_payload, entries, files)

    # The polkit subject is a fixed, validated account name.
    template = files[module.POLKIT_RULE_PATH]
    rendered = module.render_polkit_rule(template, "wis")
    assert b'subject.user == "wis"' in rendered and b"__USER__" not in rendered
    for hostile_user in ('a"b', "a\\b", "a b", "", "x" * 40, "a\nb"):
        expect_security_error(module, module.render_polkit_rule, template, hostile_user)

    print("install payload tests passed")


if __name__ == "__main__":
    main()
