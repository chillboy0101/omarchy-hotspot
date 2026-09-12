# Router-grade Device Identification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify hotspot clients from router-grade local metadata and provide a persistent user alias when privacy settings hide the device name.

**Architecture:** Capture DHCP identity fields at lease time, merge them with bounded local-name and OUI resolution, then return one stable record per associated station. Keep discovery in the helper and render it with existing Omarchy components in QML.

**Tech Stack:** Bash, dnsmasq lease hooks, Avahi, Samba `nmblookup`, IEEE OUI database, QML/Quickshell, Polkit, ShellCheck.

**Spec:** `docs/superpowers/specs/2026-09-12-router-grade-device-identification-design.md`

## Global Constraints

- Never use internet lookup, telemetry, packet capture, or OS fingerprint scanning.
- Keep device refresh bounded so native panel switching remains immediate.
- Pass secrets and aliases through stdin, never command arguments.
- Render all device-derived strings with `Text.PlainText`.
- Preserve valid UTF-8 device names and aliases, including emoji and non-Latin characters.
- Run mDNS and NetBIOS discovery only when a lease is added or changes, never during the 1.5-second panel refresh.
- Preserve the `v4-native-editor` recovery tag and all existing hotspot behavior.

---

### Task 1: Capture DHCP identity metadata

**Files:**
- Create: `src/lease-event.sh`
- Modify: `src/omarchy-hotspot-helper`
- Modify: `install.sh`
- Test: `tests/lease-event-test.sh`

**Interfaces:**
- Consumes: dnsmasq `add`, `old`, and `del` hook arguments plus `DNSMASQ_SUPPLIED_HOSTNAME`, `DNSMASQ_VENDOR_CLASS`, and `DNSMASQ_CLIENT_ID`.
- Produces: `/run/omarchy-hotspot/device-metadata.tsv` records in the form `mac<TAB>ip<TAB>hostname<TAB>vendor_class<TAB>client_id`.

- [ ] **Step 1: Write the failing lease-event test** with temporary cache paths and fixtures for add, update, deletion, missing hostname, tabs, and newlines.
- [ ] **Step 2: Run `bash tests/lease-event-test.sh`** and verify it fails because `src/lease-event.sh` does not exist.
- [ ] **Step 3: Implement `src/lease-event.sh`** using locked atomic rewrites, UTF-8-preserving control-character sanitization, and mode `600`; trigger background discovery only for new or changed leases.
- [ ] **Step 4: Add `--dhcp-script=/usr/local/lib/omarchy-hotspot-lease-event.sh`** to dnsmasq and install the hook with mode `755`.
- [ ] **Step 5: Run the lease-event test, `bash -n`, and ShellCheck** and verify all pass.
- [ ] **Step 6: Commit** with `git commit -m "Capture hotspot DHCP device metadata"`.

### Task 2: Resolve truthful device labels

**Files:**
- Modify: `src/device-identification.sh`
- Modify: `src/omarchy-hotspot-helper`
- Test: `tests/device-identification-test.sh`

**Interfaces:**
- Consumes: associated MAC, metadata record, alias record, optional cached mDNS/NetBIOS name, and OUI database.
- Produces: `resolve_device(mac, ip, metadata_file, aliases_file, oui_file)` returning `label<TAB>source` where source is `alias`, `dhcp`, `mdns`, `netbios`, `vendor`, or `unknown`.

- [ ] **Step 1: Extend the failing resolver tests** for the exact precedence order and randomized-MAC vendor suppression.
- [ ] **Step 2: Run `bash tests/device-identification-test.sh`** and verify the new assertions fail.
- [ ] **Step 3: Implement cached mDNS and NetBIOS resolution** with a combined maximum of 300 ms per newly seen IP; store the result by MAC/IP and never resolve during `clients_text()` polling.
- [ ] **Step 4: Update `clients_text()`** to emit `mac<TAB>ip<TAB>signal<TAB>connected<TAB>label<TAB>source`.
- [ ] **Step 5: Run resolver tests, syntax checks, ShellCheck, and performance checks** proving five cached clients complete within 50 ms and repeated refreshes launch no resolver processes.
- [ ] **Step 6: Commit** with `git commit -m "Resolve hotspot device names from local sources"`.

### Task 3: Add persistent device aliases

**Files:**
- Modify: `src/device-identification.sh`
- Modify: `src/omarchy-hotspot-helper`
- Modify: `config/50-omarchy-hotspot.rules`
- Test: `tests/device-alias-test.sh`

**Interfaces:**
- Consumes: stdin records `mac<TAB>alias` for `set-device-alias`; MAC-only stdin for `remove-device-alias`.
- Produces: `/var/lib/omarchy-hotspot/device-aliases.tsv`, owned by the installing user with mode `600`.

- [ ] **Step 1: Write failing tests** for add, replace, remove, invalid MAC, control characters, 49-character alias, UTF-8 names, emoji, and file permissions.
- [ ] **Step 2: Run `bash tests/device-alias-test.sh`** and verify failures identify the missing helper commands.
- [ ] **Step 3: Implement atomic alias setters** with MAC normalization, 1-48 Unicode-character validation, valid UTF-8 preservation, and separator/control-character rejection.
- [ ] **Step 4: Permit only the two alias subcommands through the existing helper dispatch** while preserving rejection of diagnostic commands over Polkit.
- [ ] **Step 5: Run alias, resolver, syntax, and ShellCheck tests** and verify all pass.
- [ ] **Step 6: Commit** with `git commit -m "Remember names for private hotspot devices"`.

### Task 4: Render the native alias flow

**Files:**
- Modify: `plugin/Panel.qml`
- Modify: `tests/panel-behavior-test.sh`

**Interfaces:**
- Consumes: six fields from `helper clients` and alias-save process results.
- Produces: native device rows showing label first, muted MAC/IP second, signal/time right, and an unboxed edit action.

- [ ] **Step 1: Add failing source-level behavior tests** asserting `PanelSectionHeader`, `TextField`, unboxed `PanelActionButton`, `Text.PlainText`, Esc cancellation, and stdin-based alias save.
- [ ] **Step 2: Run `bash tests/panel-behavior-test.sh`** and verify the alias assertions fail.
- [ ] **Step 3: Update client parsing and rows** for `ip`, `name`, and `source`; preserve Unicode and emoji, allow the full label to wrap in the flexible left column, and keep native font, spacing, muted colors, and one-click panel behavior.
- [ ] **Step 4: Implement the inline alias editor** with Save, Cancel, Esc, blank-to-remove, error text, and no status-transition text.
- [ ] **Step 5: Run panel tests and `omarchy-plugin-validate`** and verify all pass.
- [ ] **Step 6: Fully restart Omarchy Shell** and visually compare the row and editor with native Network, Bluetooth, and Tailscale panels.
- [ ] **Step 7: Commit** with `git commit -m "Add native hotspot device naming flow"`.

### Task 5: Live verification and release update

**Files:**
- Modify: `README.md`
- Modify: `docs/SECURITY.md`

**Interfaces:**
- Consumes: completed helper and panel behavior.
- Produces: install, privacy, resolution-order, and alias documentation.

- [ ] **Step 1: Install the updated helper and hook** with `pkexec ./install.sh`.
- [ ] **Step 2: Restart the active hotspot once** and verify hostapd, dnsmasq, DHCP, DNS, NAT, QR generation, and shell responsiveness.
- [ ] **Step 3: Connect the phone and verify its evidence source**; if it still withholds a name, assign an alias and verify it appears immediately and survives hotspot and shell restarts.
- [ ] **Step 4: Run all tests, ShellCheck, syntax checks, `git diff --check`, and `omarchy-plugin-validate`**.
- [ ] **Step 5: Document automatic limits and the alias fallback** in README and SECURITY without claiming model detection.
- [ ] **Step 6: Commit and push** with `git commit -m "Document router-grade device identification"` and wait for GitHub Actions to pass.
