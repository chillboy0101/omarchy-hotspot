#!/usr/bin/bash
set -euo pipefail
umask 077
while IFS= read -r environment_name; do
  unset "$environment_name" 2>/dev/null || true
done < <(compgen -e)
# shellcheck disable=SC2123 # Deliberately disable command lookup in the root discovery hook.
PATH=/nonexistent
export PATH LANG=C.UTF-8 LC_ALL=C.UTF-8

readonly STATE_TOOL=/usr/local/lib/omarchy-hotspot-secure-state
mac="${1,,}"
ip="${2:-}"

[[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || exit 0
[[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || exit 0

sanitize_field() {
  /usr/bin/printf '%s' "${1:0:255}" | /usr/bin/tr -d '\000-\037\177\t'
}

mdns=""
netbios=""
if [ -x /usr/bin/avahi-resolve-address ]; then
  mdns="$(/usr/bin/timeout --signal=KILL 1 /usr/bin/avahi-resolve-address "$ip" 2>/dev/null \
    | /usr/bin/awk '{print $2; exit}' || true)"
fi
if [ -x /usr/bin/nmblookup ]; then
  netbios="$(/usr/bin/timeout --signal=KILL 0.6 /usr/bin/nmblookup -A "$ip" 2>/dev/null \
    | /usr/bin/awk '/<00>/ && !/GROUP/ { for (i=1; i<=NF; i++) if ($i ~ /<00>/) { sub(/<00>.*/, "", $i); print $i; exit } }' || true)"
fi
mdns="$(sanitize_field "$mdns")"
netbios="$(sanitize_field "$netbios")"

/usr/bin/printf '%s\n%s\n%s\n%s\n%s\n' "$mac" "$ip" "$mdns" "$netbios" "$EPOCHSECONDS" \
  | /usr/bin/python3 "$STATE_TOOL" upsert-discovery
