#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/src/omarchy-hotspot-helper"

grep -q 'concurrent_ap_supported()' "$helper"
grep -q 'managed.*AP' "$helper"
grep -q 'cannot keep Wi-Fi connected while hosting this hotspot' "$helper"

guard_line="$(grep -n 'if ! concurrent_ap_supported' "$helper" | cut -d: -f1)"
create_line="$(grep -n 'interface add "\$VIF" type __ap' "$helper" | cut -d: -f1)"
[[ "$guard_line" -lt "$create_line" ]]

awk '
  /valid interface combinations:/ { in_combinations=1; next }
  in_combinations && /^[[:space:]]*\*/ {
    if ($0 ~ /managed/ && $0 ~ /AP/) {
      found=1
      exit
    }
  }
  END { exit(found ? 0 : 1) }
' <<'EOF'
valid interface combinations:
 * #{ managed } <= 1, #{ AP } <= 1,
   total <= 2, #channels <= 1
EOF

if awk '
  /valid interface combinations:/ { in_combinations=1; next }
  in_combinations && /^[[:space:]]*\*/ {
    if ($0 ~ /managed/ && $0 ~ /AP/) {
      found=1
      exit
    }
  }
  END { exit(found ? 0 : 1) }
' <<'EOF'
valid interface combinations:
 * #{ managed } <= 1, #{ P2P-client } <= 1,
   total <= 2, #channels <= 1
EOF
then
  echo "unsupported adapter fixture was accepted" >&2
  exit 1
fi

echo "hardware capability guard tests passed"
