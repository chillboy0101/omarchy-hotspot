#!/usr/bin/bash
set -euo pipefail
umask 077
supplied_hostname="${DNSMASQ_SUPPLIED_HOSTNAME:-}"
supplied_vendor_class="${DNSMASQ_VENDOR_CLASS:-}"
supplied_client_id="${DNSMASQ_CLIENT_ID:-}"
while IFS= read -r environment_name; do
  unset "$environment_name" 2>/dev/null || true
done < <(compgen -e)
export DNSMASQ_SUPPLIED_HOSTNAME="$supplied_hostname"
export DNSMASQ_VENDOR_CLASS="$supplied_vendor_class"
export DNSMASQ_CLIENT_ID="$supplied_client_id"
# shellcheck disable=SC2123 # Deliberately disable command lookup in the root lease hook.
PATH=/nonexistent
export PATH LANG=C.UTF-8 LC_ALL=C.UTF-8

readonly STATE_TOOL=/usr/local/lib/omarchy-hotspot-secure-state
readonly DISCOVER_TOOL=/usr/local/lib/omarchy-hotspot-discover-device.sh

action="${1:-}"
mac="${2,,}"
ip="${3:-}"
hostname="${DNSMASQ_SUPPLIED_HOSTNAME:-${4:-}}"
vendor_class="$DNSMASQ_VENDOR_CLASS"
client_id="$DNSMASQ_CLIENT_ID"

[[ "$action" =~ ^(add|old|del)$ ]] || exit 0
[[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || exit 0
[[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || exit 0

sanitize_field() {
  /usr/bin/printf '%s' "${1:0:255}" | /usr/bin/tr -d '\000-\037\177\t'
}

hostname="$(sanitize_field "$hostname")"
vendor_class="$(sanitize_field "$vendor_class")"
client_id="$(sanitize_field "$client_id")"

if [ "$action" = del ]; then
  /usr/bin/printf '%s\n' "$mac" | /usr/bin/python3 "$STATE_TOOL" delete-metadata
  /usr/bin/printf '%s\n' "$mac" | /usr/bin/python3 "$STATE_TOOL" delete-discovery
  exit 0
fi

/usr/bin/printf '%s\n%s\n%s\n%s\n%s\n' "$mac" "$ip" "$hostname" "$vendor_class" "$client_id" \
  | /usr/bin/python3 "$STATE_TOOL" upsert-metadata

unit="omarchy-hotspot-discover-${mac//:/}.service"
/usr/bin/systemd-run --quiet --collect --unit="$unit" \
  /usr/bin/timeout --signal=KILL 2 /usr/bin/bash "$DISCOVER_TOOL" "$mac" "$ip" \
  >/dev/null 2>&1 || true
