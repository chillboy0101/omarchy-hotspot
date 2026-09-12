#!/usr/bin/env bash
set -euo pipefail

metadata_file="${OMARCHY_HOTSPOT_METADATA_FILE:-/run/omarchy-hotspot/device-metadata.tsv}"
discovery_file="${OMARCHY_HOTSPOT_DISCOVERY_FILE:-/run/omarchy-hotspot/device-discovery.tsv}"
action="${1:-}"
mac="${2,,}"
ip="${3:-}"
hostname="${DNSMASQ_SUPPLIED_HOSTNAME:-${4:-}}"
vendor_class="${DNSMASQ_VENDOR_CLASS:-}"
client_id="${DNSMASQ_CLIENT_ID:-}"

sanitize_field() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'
}

hostname="$(sanitize_field "$hostname")"
vendor_class="$(sanitize_field "$vendor_class")"
client_id="$(sanitize_field "$client_id")"

mkdir -p "$(dirname "$metadata_file")"
touch "$metadata_file"
chmod 600 "$metadata_file"

exec 9>"$metadata_file.lock"
flock 9
tmp="$(mktemp "${metadata_file}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
awk -F '\t' -v wanted="$mac" 'tolower($1) != wanted' "$metadata_file" >"$tmp"
if [ "$action" != del ]; then
  printf '%s\t%s\t%s\t%s\t%s\n' "$mac" "$ip" "$hostname" "$vendor_class" "$client_id" >>"$tmp"
fi
chmod 600 "$tmp"
mv -f "$tmp" "$metadata_file"
trap - EXIT

if [ "$action" = del ] && [ -f "$discovery_file" ]; then
  tmp="$(mktemp "${discovery_file}.XXXXXX")"
  awk -F '\t' -v wanted="$mac" 'tolower($1) != wanted' "$discovery_file" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$discovery_file"
fi

if [ "$action" != del ]; then
  discover_command="${OMARCHY_HOTSPOT_DISCOVER_COMMAND:-/usr/local/lib/omarchy-hotspot-discover-device.sh}"
  if [ -x "$discover_command" ]; then
    "$discover_command" "$mac" "$ip" >/dev/null 2>&1 &
  fi
fi
