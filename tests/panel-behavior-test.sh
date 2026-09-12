#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel="$repo_dir/plugin/Panel.qml"

editor_flow="$(sed -n '/function startHotspotEdit()/,/^  }/p' "$panel")"
if grep -Eq 'hotspotNameField\.(selectAll|forceActiveFocus)' <<<"$editor_flow"; then
  echo "editor must let the user choose which field to focus" >&2
  exit 1
fi

echo "panel behavior tests passed"
