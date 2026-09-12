#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/src/device-identification.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/leases" <<'EOF'
2000000000 a8:bb:cc:11:22:33 10.42.0.10 Pixel-Phone 01:a8:bb:cc:11:22:33
2000000000 dc:ad:be:44:55:66 10.42.0.11 * 01:dc:ad:be:44:55:66
EOF

cat >"$tmp_dir/oui" <<'EOF'
A8BBCC     (base 16)        Example Mobile Ltd.
DCADBE     (base 16)        Backup Devices Inc.
EOF

[[ "$(lease_hostname 'A8:BB:CC:11:22:33' "$tmp_dir/leases")" == "Pixel-Phone" ]]
[[ -z "$(lease_hostname 'dc:ad:be:44:55:66' "$tmp_dir/leases")" ]]
[[ "$(mac_vendor 'a8:bb:cc:11:22:33' "$tmp_dir/oui")" == "Example Mobile Ltd." ]]
[[ "$(device_label 'a8:bb:cc:11:22:33' "$tmp_dir/leases" "$tmp_dir/oui" '')" == "Pixel-Phone" ]]
[[ "$(device_label 'dc:ad:be:44:55:66' "$tmp_dir/leases" "$tmp_dir/oui" 'living-room-phone.local')" == "living-room-phone" ]]
[[ "$(device_label 'dc:ad:be:44:55:66' "$tmp_dir/leases" "$tmp_dir/oui" '')" == "Backup Devices Inc. device" ]]
[[ "$(device_label '02:00:00:44:55:66' "$tmp_dir/leases" "$tmp_dir/oui" '')" == "Unknown device" ]]

echo "device identification tests passed"
