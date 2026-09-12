#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel="$repo_dir/plugin/Panel.qml"

editor_flow="$(sed -n '/function startHotspotEdit()/,/^  }/p' "$panel")"
if grep -Eq 'hotspotNameField\.(selectAll|forceActiveFocus)' <<<"$editor_flow"; then
  echo "editor must let the user choose which field to focus" >&2
  exit 1
fi

grep -q 'function startDeviceAlias' "$panel"
grep -q 'function saveDeviceAlias' "$panel"
grep -q 'set-device-alias' "$panel"
grep -q 'aliasProc.write' "$panel"
grep -q 'modelData.ip' "$panel"
grep -q 'wrapMode: Text.Wrap' "$panel"
grep -q 'disconnect-device' "$panel"
grep -q 'block-device' "$panel"
grep -q 'unblock-device' "$panel"
grep -q 'text: "BLOCKED DEVICES"' "$panel"
grep -q 'tooltipText: "Disconnect"' "$panel"
grep -q 'tooltipText: "Block"' "$panel"
grep -q 'tooltipText: "Unblock"' "$panel"

echo "panel behavior tests passed"
