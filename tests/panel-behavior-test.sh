#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel="$repo_dir/plugin/Panel.qml"

grep -q 'trim().split("\\t")' "$panel"
grep -q 'btn === Qt.RightButton.*root.toggleHotspot' "$panel"
grep -q 'btn === Qt.MiddleButton.*root.refresh' "$panel"

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
grep -q 'text: "Disconnect"' "$panel"
if grep -q 'tooltipText: "Disconnect"' "$panel"; then
  echo "disconnect must use the native row tooltip, not a separate button" >&2
  exit 1
fi
grep -q 'tooltipText: "Block"' "$panel"
grep -q 'text: "Unblock"' "$panel"
grep -q 'property int deviceIndex:' "$panel"
grep -q 'property int blockedIndex:' "$panel"
grep -q 'focusSection === "devices"' "$panel"
grep -q 'focusSection === "blocked"' "$panel"
if grep -q 'current: true' "$panel"; then
  echo "connected device rows must not remain permanently selected" >&2
  exit 1
fi
grep -q 'readonly property bool showRowActions:' "$panel"
grep -q 'readonly property bool canRename:' "$panel"
grep -q 'visible: deviceRow.showRowActions && deviceRow.canRename' "$panel"
grep -q 'id: deviceRowHover' "$panel"
grep -q 'id: blockedRowHover' "$panel"
if grep -q 'function clearDeviceRowSelection' "$panel"; then
  echo "device cursor must remain on the last hovered row" >&2
  exit 1
fi
grep -q 'id: deviceDetails' "$panel"
grep -q 'elide: Text.ElideRight' "$panel"
if grep -q 'wrapMode: Text.WrapAnywhere' "$panel"; then
  echo "device details must remain on one aligned row" >&2
  exit 1
fi

# Qt's TextInput reads the Wayland clipboard on its own, so editable fields
# use the key-only KeyField instead of TextField/TextInput/TextEdit.
key_field="$repo_dir/plugin/KeyField.qml"
[[ -f "$key_field" ]]
for qml in "$panel" "$key_field"; do
  if grep -Eq '\b(TextField|TextInput|TextEdit)[[:space:]]*\{' "$qml"; then
    echo "$(basename "$qml") must not instantiate Qt text inputs" >&2
    exit 1
  fi
done
if grep -Eq '\b(TextField|TextInput)\b' "$panel"; then
  echo "Panel.qml must not reference TextField or TextInput" >&2
  exit 1
fi
if grep -Eq 'createQmlObject|createComponent|Loader' "$key_field"; then
  echo "KeyField.qml must not create items dynamically" >&2
  exit 1
fi
[[ "$(grep -c '^[[:space:]]*KeyField {' "$panel")" -eq 3 ]]
grep -q 'id: hotspotNameField' "$panel"
grep -q 'password: !root.showEditPassword' "$panel"
grep -q 'onTextEdited: function(value)' "$panel"
grep -q 'onCancelled: root.cancelHotspotEdit()' "$panel"
grep -q 'onCancelled: root.cancelDeviceAlias()' "$panel"
grep -q '^FocusScope {' "$key_field"
grep -q 'signal textEdited(string value)' "$key_field"
grep -q 'Qt.Key_Backspace' "$key_field"
grep -q '0xdc00' "$key_field"

# WPA passphrases may start or end with spaces; reading one must keep them.
grep -q 'var password = String(stdoutText || "").replace(/\\r?\\n$/, "")' "$panel"
if grep -q 'var password = String(stdoutText || "").trim()' "$panel"; then
  echo "password reads must not trim valid passphrase spaces" >&2
  exit 1
fi

echo "panel behavior tests passed"
