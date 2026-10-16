#!/usr/bin/bash
# Omarchy Hotspot installer — system bits.
# (The bar widget itself installs via: omarchy plugin add <repo-url>)
# Installs the root helper, the passwordless polkit rule, and the
# NetworkManager exemption for the AP virtual interface.
#
# src/install-payload.py verifies every allowlisted file against
# payload.sha256 before asking for root, then hands the verified bytes to the
# privileged stage over a pipe. Root never reads from this checkout.
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE

REPO_DIR="$(/usr/bin/dirname "$(/usr/bin/readlink -f "$0")")"
exec /usr/bin/python3 -I -S "$REPO_DIR/src/install-payload.py" --stage "$REPO_DIR"
