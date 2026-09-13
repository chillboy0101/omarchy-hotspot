#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/src/discover-device.sh"
helper="$repo_dir/src/omarchy-hotspot-helper"

[[ "$(head -n1 "$script")" == '#!/usr/bin/bash' ]]
grep -q 'PATH=/nonexistent' "$script"
grep -q '/usr/bin/avahi-resolve-address' "$script"
grep -q '/usr/bin/nmblookup' "$script"
grep -q 'upsert-discovery' "$script"
grep -q '"$EPOCHSECONDS"' "$script"
grep -q 'schedule_device_discovery' "$helper"
grep -q 'EPOCHSECONDS - discovery_attempt >= 60' "$helper"
! grep -Eq '>>|OMARCHY_HOTSPOT_.*COMMAND|OMARCHY_HOTSPOT_DISCOVERY_FILE' "$script"

echo "discovery tests passed"
