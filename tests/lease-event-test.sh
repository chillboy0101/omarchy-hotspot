#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/src/lease-event.sh"

[[ "$(head -n1 "$script")" == '#!/usr/bin/bash' ]]
grep -q 'PATH=/nonexistent' "$script"
grep -q 'upsert-metadata' "$script"
grep -q 'delete-metadata' "$script"
grep -q 'delete-discovery' "$script"
grep -q '/usr/bin/systemd-run' "$script"
! grep -Eq '>>|OMARCHY_HOTSPOT_(METADATA|DISCOVERY|DISCOVER_COMMAND)' "$script"

echo "lease event tests passed"
