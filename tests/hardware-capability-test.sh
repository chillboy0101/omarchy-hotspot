#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/src/omarchy-hotspot-helper"

grep -q "interface add \"\$VIF\" type __ap" "$helper"
grep -q 'driver .*cannot create a concurrent AP interface' "$helper"
grep -q 'cannot keep Wi-Fi connected while hosting this hotspot' "$helper"
grep -q 'current_ap_mac=' "$helper"
grep -q "if \[\[ \"\${current_ap_mac,,}\" != \"\${ap_mac,,}\" \]\]" "$helper"
grep -q 'failed to set the hotspot interface MAC address' "$helper"

create_line="$(grep -n "interface add \"\$VIF\" type __ap" "$helper" | cut -d: -f1)"
failure_line="$(sed -n "${create_line},$((create_line + 3))p" "$helper" | grep -n 'if ! iw phy' | cut -d: -f1)"
[[ -n "$failure_line" ]]

mac_guard_line="$(grep -n "if \[\[ \"\${current_ap_mac,,}\" != \"\${ap_mac,,}\" \]\]" "$helper" | cut -d: -f1)"
mac_set_line="$(grep -n "if ! ip link set \"\$VIF\" address \"\$ap_mac\"" "$helper" | cut -d: -f1)"
[[ "$mac_guard_line" -lt "$mac_set_line" ]]

if grep -q 'ip link set "\$VIF" up' "$helper"; then
  echo "startup must let hostapd bring the AP interface up" >&2
  exit 1
fi

echo "hardware capability guard tests passed"
