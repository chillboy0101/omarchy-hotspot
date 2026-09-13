#!/usr/bin/bash
# Omarchy Hotspot installer — system bits.
# (The bar widget itself installs via: omarchy plugin add <repo-url>)
# Installs the root helper, the passwordless polkit rule, and the
# NetworkManager exemption for the AP virtual interface.
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE

REPO_DIR="$(/usr/bin/dirname "$(/usr/bin/readlink -f "$0")")"
HELPER_SRC="$REPO_DIR/src/omarchy-hotspot-helper"
DEVICE_ID_SRC="$REPO_DIR/src/device-identification.sh"
LEASE_EVENT_SRC="$REPO_DIR/src/lease-event.sh"
DISCOVER_DEVICE_SRC="$REPO_DIR/src/discover-device.sh"
STATE_TOOL_SRC="$REPO_DIR/src/secure-state.py"
RULES_SRC="$REPO_DIR/config/50-omarchy-hotspot.rules"
NM_CONF_SRC="$REPO_DIR/config/99-unmanaged-ap0.conf"
if (( EUID != 0 )); then
  exec /usr/bin/pkexec /usr/bin/bash "$0" "$@"
fi

caller_uid="${PKEXEC_UID:-}"
sudo_user="${SUDO_USER:-}"
while IFS= read -r environment_name; do
  unset "$environment_name" 2>/dev/null || true
done < <(compgen -e)
if [[ "$caller_uid" =~ ^[0-9]+$ ]]; then
  export PKEXEC_UID="$caller_uid"
fi
if [ -n "$sudo_user" ]; then
  export SUDO_USER="$sudo_user"
fi
PATH=/nonexistent
export PATH
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# pkexec clears the environment and runs as root, so $USER/$(whoami) would be
# "root" here and the polkit rule would match the wrong subject. pkexec exports
# PKEXEC_UID for the real caller; fall back to SUDO_USER / logname / id.
if [ -n "${PKEXEC_UID:-}" ]; then
  INSTALL_USER="$(/usr/bin/id -nu "$PKEXEC_UID")"
elif [ -n "${SUDO_USER:-}" ]; then
  INSTALL_USER="$SUDO_USER"
elif /usr/bin/logname >/dev/null 2>&1; then
  INSTALL_USER="$(/usr/bin/logname)"
else
  INSTALL_USER="$(/usr/bin/id -un)"
fi

echo "==> Installing packages (hostapd, dnsmasq)"
/usr/bin/pacman -S --noconfirm --needed hostapd dnsmasq

echo "==> Installing helper to /usr/local/bin"
/usr/bin/install -d -m 755 /usr/local/bin /usr/local/lib
/usr/bin/install -m 755 "$STATE_TOOL_SRC" /usr/local/lib/omarchy-hotspot-secure-state
/usr/bin/install -m 755 "$HELPER_SRC" /usr/local/bin/omarchy-hotspot-helper
/usr/bin/install -m 644 "$DEVICE_ID_SRC" /usr/local/lib/omarchy-hotspot-device-identification.sh
/usr/bin/install -m 755 "$LEASE_EVENT_SRC" /usr/local/lib/omarchy-hotspot-lease-event.sh
/usr/bin/install -m 755 "$DISCOVER_DEVICE_SRC" /usr/local/lib/omarchy-hotspot-discover-device.sh
/usr/bin/python3 /usr/local/lib/omarchy-hotspot-secure-state init

echo "==> Installing polkit rule (passwordless pkexec for the helper)"
# Use awk (not sed) so the username is treated as a fixed string, never as a
# regex or replacement pattern.
/usr/bin/awk -v u="$INSTALL_USER" '{ gsub(/__USER__/, u) } 1' "$RULES_SRC" \
  | /usr/bin/python3 /usr/local/lib/omarchy-hotspot-secure-state write-polkit-rule

echo "==> Telling NetworkManager to leave ap0 alone"
/usr/bin/cat "$NM_CONF_SRC" \
  | /usr/bin/python3 /usr/local/lib/omarchy-hotspot-secure-state write-nm-config
/usr/bin/nmcli general reload || true

echo
echo "Done! Now install the widget with:"
echo "  omarchy plugin add https://github.com/chillboy0101/omarchy-hotspot"
echo "  omarchy plugin enable io.github.chillboy0101.omarchy-hotspot --section right"
