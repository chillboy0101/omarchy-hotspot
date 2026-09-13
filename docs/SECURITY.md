# Security

Omarchy Hotspot uses a small privileged helper because creating an AP,
configuring forwarding, and controlling hostapd require root. This document
describes the boundary used by the 1.0 release.

## Privilege boundary

- Polkit authorizes only `/usr/local/bin/omarchy-hotspot-helper`, and only for
  the desktop user who ran the installer.
- The helper exposes a closed subcommand allowlist. Diagnostic packet capture,
  arbitrary command execution, and arbitrary file access are not available.
- The helper has a fixed `/usr/bin/bash` interpreter, clears shell startup
  variables and the inherited environment, sets `PATH=/nonexistent`, and
  invokes external tools through an explicit absolute-path allowlist.
- Root-sourced support code and the secure-state program must be regular,
  root-owned files that are not writable by group or other users.

## Process handling

- QML never constructs `bash -c` strings. Commands and arguments remain
  separate throughout the process API.
- Every QML child runs through `plugin/run-bounded.py`, which creates a new
  process group, applies a wall-clock deadline, enforces a live combined-output
  byte cap, and terminates the complete group on timeout or overflow.
- QML consumes output incrementally with `SplitParser` and applies a second
  in-process 64 KiB cap. It does not use unbounded `StdioCollector` buffers.
- Passwords travel through stdin. They never appear in argv. QR generation and
  clipboard copying also receive the secret through bounded stdin readers.

## State and configuration files

`src/secure-state.py` owns all privileged writes. It:

- opens allowlisted directories once with `O_DIRECTORY | O_NOFOLLOW`;
- verifies parent/directory ownership and type before use;
- rejects symlinks, non-regular files, hard-linked files, unexpected owners,
  unsafe modes, oversized input, and control characters;
- writes to an exclusive random file through the retained directory descriptor,
  calls `fsync`, then atomically renames and syncs the directory;
- serializes state updates with a root-owned lock so simultaneous device events
  cannot overwrite one another;
- safely migrates the previous installation's validated files to root ownership.

Migration and default creation run only during install or hotspot start. Normal
status and credential reads are read-only and open only their required state
directory.

Runtime permissions:

- `/var/lib/omarchy-hotspot/` — root-owned `700`.
- `password`, `ssid`, `device-aliases.tsv`, and `blocked-devices.tsv` —
  root-owned `600`.
- `/run/omarchy-hotspot/` — root-owned `700`.
- `hostapd.conf`, device metadata, and discovery cache — root-owned `600`.
- Installed helper programs — root-owned and not writable by unprivileged users.

The password is returned only through the helper's allowlisted `read-password`
action to the polkit-authorized desktop user. Other local users cannot read the
state directory or invoke that passwordless helper rule.

## Untrusted device data

DHCP, mDNS, and NetBIOS names are bounded, stripped of control characters,
stored atomically, and rendered as `Text.PlainText`. Device actions accept only
a validated six-octet MAC address. Discovery is local, has subsecond command
deadlines, and uses no telemetry or external lookup service.

## Verification

`tests/security-hardening-test.sh` checks the executable boundary and runs
unit tests for process timeouts/output caps plus no-follow atomic storage.
GitHub Actions also runs ShellCheck, Bash/Python syntax checks, the security
suite, manifest validation, and the plugin behavior tests.
