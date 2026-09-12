#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
export OMARCHY_HOTSPOT_DISCOVERY_FILE="$tmp_dir/discovery.tsv"
export OMARCHY_HOTSPOT_AVAHI_COMMAND="$tmp_dir/avahi"
export OMARCHY_HOTSPOT_NMBLOOKUP_COMMAND="$tmp_dir/nmblookup"

cat >"$OMARCHY_HOTSPOT_AVAHI_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" 'Carl📱.local'
EOF
cat >"$OMARCHY_HOTSPOT_NMBLOOKUP_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '10.42.0.10 CARL-PHONE<00>\n'
EOF
chmod 755 "$OMARCHY_HOTSPOT_AVAHI_COMMAND" "$OMARCHY_HOTSPOT_NMBLOOKUP_COMMAND"

"$repo_dir/src/discover-device.sh" a8:bb:cc:11:22:33 10.42.0.10
[[ "$(cut -f3 "$OMARCHY_HOTSPOT_DISCOVERY_FILE")" == 'Carl📱.local' ]]
[[ "$(cut -f4 "$OMARCHY_HOTSPOT_DISCOVERY_FILE")" == 'CARL-PHONE' ]]

echo "discovery tests passed"
