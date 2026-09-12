#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/src/device-identification.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
aliases="$tmp_dir/aliases.tsv"

set_device_alias 'A8:BB:CC:11:22:33' 'Carl 📱' "$aliases"
[[ "$(cat "$aliases")" == $'a8:bb:cc:11:22:33\tCarl 📱' ]]
[[ "$(stat -c %a "$aliases")" == 600 ]]
set_device_alias 'a8:bb:cc:11:22:33' 'Carl 🚀' "$aliases"
[[ "$(cut -f2 "$aliases")" == 'Carl 🚀' ]]

if set_device_alias 'invalid' 'Phone' "$aliases" 2>/dev/null; then exit 1; fi
if set_device_alias 'a8:bb:cc:11:22:33' $'Bad\tName' "$aliases" 2>/dev/null; then exit 1; fi
if set_device_alias 'a8:bb:cc:11:22:33' '1234567890123456789012345678901234567890123456789' "$aliases" 2>/dev/null; then exit 1; fi

remove_device_alias 'a8:bb:cc:11:22:33' "$aliases"
[[ ! -s "$aliases" ]]
echo "device alias tests passed"
