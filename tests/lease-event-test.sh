#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
export OMARCHY_HOTSPOT_METADATA_FILE="$tmp_dir/metadata.tsv"
export OMARCHY_HOTSPOT_DISCOVERY_FILE="$tmp_dir/discovery.tsv"
export OMARCHY_HOTSPOT_OUI_FILE="$tmp_dir/oui.txt"
export DNSMASQ_SUPPLIED_HOSTNAME='Carl📱'
export DNSMASQ_VENDOR_CLASS='android-dhcp'
export DNSMASQ_CLIENT_ID='01:aa:bb:cc:dd:ee:ff'

cat >"$OMARCHY_HOTSPOT_OUI_FILE" <<'EOF'
A8BBCC     (base 16)        Example Mobile Ltd.
EOF

"$repo_dir/src/lease-event.sh" add a8:bb:cc:dd:ee:ff 10.42.0.10 'Carl📱'
[[ "$(cut -f3 "$OMARCHY_HOTSPOT_METADATA_FILE")" == 'Carl📱' ]]
[[ "$(cut -f4 "$OMARCHY_HOTSPOT_METADATA_FILE")" == 'android-dhcp' ]]
[[ "$(cut -f5 "$OMARCHY_HOTSPOT_METADATA_FILE")" == '01:aa:bb:cc:dd:ee:ff' ]]
[[ "$(stat -c %a "$OMARCHY_HOTSPOT_METADATA_FILE")" == 600 ]]

DNSMASQ_SUPPLIED_HOSTNAME='' "$repo_dir/src/lease-event.sh" old a8:bb:cc:dd:ee:ff 10.42.0.11 ''
[[ "$(cut -f2 "$OMARCHY_HOTSPOT_METADATA_FILE")" == '10.42.0.11' ]]

"$repo_dir/src/lease-event.sh" del a8:bb:cc:dd:ee:ff 10.42.0.11 ''
[[ ! -s "$OMARCHY_HOTSPOT_METADATA_FILE" ]]

echo "lease event tests passed"
