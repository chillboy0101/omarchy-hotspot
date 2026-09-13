#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel="$repo_dir/plugin/Panel.qml"
helper="$repo_dir/src/omarchy-hotspot-helper"
installer="$repo_dir/install.sh"
qr="$repo_dir/plugin/qr.sh"

[[ "$(head -n1 "$helper")" == '#!/usr/bin/bash' ]]
[[ "$(head -n1 "$installer")" == '#!/usr/bin/bash' ]]
[[ "$(head -n1 "$qr")" == '#!/usr/bin/bash' ]]
[[ "$(head -n1 "$repo_dir/plugin/run-bounded.py")" == '#!/usr/bin/python3' ]]
[[ "$(head -n1 "$repo_dir/plugin/copy-secret.py")" == '#!/usr/bin/python3' ]]
[[ "$(head -n1 "$repo_dir/src/secure-state.py")" == '#!/usr/bin/python3' ]]

grep -q 'run-bounded.py' "$panel"
grep -q '"/usr/bin/pkexec"' "$panel"
grep -q '"/usr/bin/wl-copy"' "$repo_dir/plugin/copy-secret.py"
grep -q 'read-password' "$panel"
grep -q 'write-hostapd' "$helper"
grep -q 'PATH=/nonexistent' "$helper"
grep -q 'compgen -e' "$helper"
grep -q 'if command == "init"' "$repo_dir/src/secure-state.py"
grep -q "printf 'on\\\\t%s\\\\t%s\\\\t%s\\\\t%s\\\\n'" "$helper"

if grep -q 'bash.*,.*-c' "$panel"; then
  echo "panel must not construct shell commands" >&2
  exit 1
fi
if grep -q 'StdioCollector' "$panel"; then
  echo "panel process output must be streamed through bounded collectors" >&2
  exit 1
fi
if grep -q '/var/lib/omarchy-hotspot' "$qr"; then
  echo "QR generator must receive secrets over stdin" >&2
  exit 1
fi
if grep -Eq '>[[:space:]]*"?\$(PASS_FILE|SSID_FILE|AP_CONF)' "$helper"; then
  echo "privileged state must use the no-follow atomic state writer" >&2
  exit 1
fi

/usr/bin/python3 "$repo_dir/tests/test_secure_state.py"
/usr/bin/python3 "$repo_dir/tests/test_run_bounded.py"

echo "security hardening tests passed"
