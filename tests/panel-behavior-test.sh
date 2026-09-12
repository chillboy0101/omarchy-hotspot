#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel="$repo_dir/plugin/Panel.qml"

editor_flow="$(sed -n '/function startHotspotEdit()/,/^  }/p' "$panel")"
grep -q 'hotspotNameField\.selectAll()' <<<"$editor_flow"
grep -q 'hotspotNameField\.forceActiveFocus()' <<<"$editor_flow"

echo "panel behavior tests passed"
