#!/usr/bin/env bash
set -euo pipefail

mac="${1,,}"
ip="$2"
discovery_file="${OMARCHY_HOTSPOT_DISCOVERY_FILE:-/run/omarchy-hotspot/device-discovery.tsv}"
avahi_command="${OMARCHY_HOTSPOT_AVAHI_COMMAND:-/usr/bin/avahi-resolve-address}"
nmblookup_command="${OMARCHY_HOTSPOT_NMBLOOKUP_COMMAND:-/usr/bin/nmblookup}"

sanitize_field() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'
}

mkdir -p "$(dirname "$discovery_file")"
touch "$discovery_file"
chmod 600 "$discovery_file"

if awk -F '\t' -v wanted_mac="$mac" -v wanted_ip="$ip" \
  'tolower($1) == wanted_mac && $2 == wanted_ip { found=1 } END { exit !found }' "$discovery_file"; then
  exit 0
fi

mdns=""
netbios=""
if [ -x "$avahi_command" ]; then
  mdns="$(timeout 0.3 "$avahi_command" "$ip" 2>/dev/null | awk '{print $2; exit}' || true)"
fi
if [ -x "$nmblookup_command" ]; then
  netbios="$(timeout 0.3 "$nmblookup_command" -A "$ip" 2>/dev/null | awk '/<00>/ && !/GROUP/ { for (i=1; i<=NF; i++) if ($i ~ /<00>/) { sub(/<00>.*/, "", $i); print $i; exit } }' || true)"
fi
mdns="$(sanitize_field "$mdns")"
netbios="$(sanitize_field "$netbios")"

exec 9>"$discovery_file.lock"
flock 9
tmp="$(mktemp "${discovery_file}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
awk -F '\t' -v wanted="$mac" 'tolower($1) != wanted' "$discovery_file" >"$tmp"
printf '%s\t%s\t%s\t%s\n' "$mac" "$ip" "$mdns" "$netbios" >>"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$discovery_file"
trap - EXIT
