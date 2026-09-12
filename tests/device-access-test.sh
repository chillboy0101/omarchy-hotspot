#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/src/device-identification.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
blocked="$tmp_dir/blocked.tsv"

block_device 'A8:BB:CC:11:22:33' 'Carl 📱' "$blocked"
[[ "$(cat "$blocked")" == $'a8:bb:cc:11:22:33\tCarl 📱' ]]
[[ "$(stat -c %a "$blocked")" == 600 ]]
block_device 'a8:bb:cc:11:22:33' 'Carl 🚀' "$blocked"
[[ "$(wc -l <"$blocked")" == 1 ]]
[[ "$(cut -f2 "$blocked")" == 'Carl 🚀' ]]
if block_device 'bad-address' 'Bad' "$blocked" 2>/dev/null; then exit 1; fi

unblock_device 'a8:bb:cc:11:22:33' "$blocked"
[[ ! -s "$blocked" ]]
echo "device access tests passed"
