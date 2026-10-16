#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_dir/src/omarchy-hotspot-helper"

grep -q "interface add \"\$VIF\" type __ap" "$helper"
grep -q 'driver .*cannot create a concurrent AP interface' "$helper"
grep -q 'cannot keep Wi-Fi connected while hosting this hotspot' "$helper"
grep -q 'current_ap_mac=' "$helper"
grep -q "if \[\[ \"\${current_ap_mac,,}\" != \"\${ap_mac,,}\" \]\]" "$helper"
grep -q 'failed to set the hotspot interface MAC address' "$helper"

create_line="$(grep -n "interface add \"\$VIF\" type __ap" "$helper" | cut -d: -f1)"
failure_line="$(sed -n "${create_line},$((create_line + 3))p" "$helper" | grep -n 'if ! iw phy' | cut -d: -f1)"
[[ -n "$failure_line" ]]

mac_guard_line="$(grep -n "if \[\[ \"\${current_ap_mac,,}\" != \"\${ap_mac,,}\" \]\]" "$helper" | cut -d: -f1)"
mac_set_line="$(grep -n "if ! ip link set \"\$VIF\" address \"\$ap_mac\"" "$helper" | cut -d: -f1)"
[[ "$mac_guard_line" -lt "$mac_set_line" ]]

if grep -q "ip link set \"\$VIF\" up" "$helper"; then
  echo "startup must let hostapd bring the AP interface up" >&2
  exit 1
fi

grep -q "hostapd_cli -p /run/hostapd -i \"\$VIF\" status" "$helper"
grep -q "grep -qx 'state=ENABLED'" "$helper"
wait_line="$(grep -n 'wait_for_hostapd' "$helper" | head -1 | cut -d: -f1)"
dns_line="$(grep -n 'systemd-run --unit=omarchy-hotspot-dns' "$helper" | head -1 | cut -d: -f1)"
[[ "$wait_line" -lt "$dns_line" ]]

# Render hostapd.conf with the helper's own functions for a station link as
# `iw dev <station> info` prints it, e.g. "9 (2452 MHz), width: 20 MHz, ...".
hostapd_conf_for() {
  local link="$1"
  # shellcheck disable=SC2034,SC2329 # The evaluated helper functions use these stubs.
  (
    eval "$(awk '/^(station_channel|station_width|station_center_offset|station_vht_center|ht40_in_block|vht_block_center|write_hostapd_conf)[(][)] [{]$/,/^}$/' "$helper")"
    VIF=ap0 BLOCKED_FILE=/dev/null
    station_iface() { echo wlo1; }
    iw() { printf '\tchannel %s\n' "$link"; }
    ap_ssid() { echo test-ssid; }
    state_store() { if [[ "$1" == write-hostapd ]]; then cat; else echo test-pass; fi; }
    write_hostapd_conf
  )
}

expect_conf() {
  local link="$1" conf line
  shift
  conf="$(hostapd_conf_for "$link")"
  for line in "$@"; do
    if ! grep -qxF -- "$line" <<<"$conf"; then
      echo "station '$link': hostapd.conf lacks '$line'" >&2
      exit 1
    fi
  done
}

expect_no_key() {
  local link="$1" conf key
  shift
  conf="$(hostapd_conf_for "$link")"
  for key in "$@"; do
    if grep -q "^$key=" <<<"$conf"; then
      echo "station '$link': hostapd.conf must not set '$key'" >&2
      exit 1
    fi
  done
}

# HT must be on at every width (ht_capab alone leaves a 54 Mbps 802.11g AP),
# on the station's primary channel and HT40 pair.
expect_conf '9 (2452 MHz), width: 20 MHz, center1: 2452 MHz' \
  hw_mode=g channel=9 ieee80211n=1 wmm_enabled=1 'ht_capab=[HT20]'
expect_conf '1 (2412 MHz), width: 40 MHz, center1: 2422 MHz' \
  channel=1 ieee80211n=1 wmm_enabled=1 'ht_capab=[HT40+]'
expect_conf '9 (2452 MHz), width: 40 MHz, center1: 2442 MHz' \
  channel=9 ieee80211n=1 wmm_enabled=1 'ht_capab=[HT40-]'
# VHT requires HT, and hostapd only accepts the primary's own HT40 pair.
expect_conf '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
  hw_mode=a channel=36 ieee80211n=1 wmm_enabled=1 ieee80211ac=1 \
  'ht_capab=[HT40+]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42
expect_conf '40 (5200 MHz), width: 80 MHz, center1: 5210 MHz' \
  channel=40 ieee80211n=1 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_centr_freq_seg0_idx=42
expect_conf '157 (5785 MHz), width: 80 MHz, center1: 5775 MHz' \
  channel=157 ieee80211n=1 ieee80211ac=1 'ht_capab=[HT40+]' vht_oper_centr_freq_seg0_idx=155
expect_conf '161 (5805 MHz), width: 80 MHz, center1: 5775 MHz' \
  channel=161 ieee80211n=1 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_centr_freq_seg0_idx=155
# At 160 MHz seg0 is the 160 MHz center. hostapd 2.12 rejects seg1 there
# ("160 MHz: center segment 1 should not be set"); only 80+80 uses it.
expect_conf '104 (5520 MHz), width: 160 MHz, center1: 5570 MHz' \
  channel=104 ieee80211n=1 ieee80211ac=1 'ht_capab=[HT40-]' \
  vht_oper_chwidth=2 vht_oper_centr_freq_seg0_idx=114
expect_no_key '104 (5520 MHz), width: 160 MHz, center1: 5570 MHz' vht_oper_centr_freq_seg1_idx
expect_conf '116 (5580 MHz), width: 160 MHz, center1: 5570 MHz' \
  channel=116 ieee80211ac=1 'ht_capab=[HT40+]' vht_oper_chwidth=2 vht_oper_centr_freq_seg0_idx=114
expect_no_key '116 (5580 MHz), width: 160 MHz, center1: 5570 MHz' vht_oper_centr_freq_seg1_idx

# Without center1 the block comes from the 5 GHz grid. The old channel + 4
# fallback named a block that starts off the grid, which hostapd rejects as
# "Frequency not present (seg0)"; its coupling check (seg0 = channel +-2 or
# +-6 at 80 MHz) rejects it too.
expect_conf '36 (5180 MHz), width: 80 MHz' \
  channel=36 ieee80211ac=1 'ht_capab=[HT40+]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42
expect_conf '48 (5240 MHz), width: 80 MHz' \
  channel=48 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42
expect_conf '161 (5805 MHz), width: 80 MHz' \
  channel=161 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=155
expect_conf '104 (5520 MHz), width: 160 MHz' \
  channel=104 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_chwidth=2 vht_oper_centr_freq_seg0_idx=114
expect_no_key '104 (5520 MHz), width: 160 MHz' vht_oper_centr_freq_seg1_idx
# Channels 132-144 belong to no 160 MHz block; fall back to HT20, no VHT.
expect_conf '132 (5660 MHz), width: 160 MHz' channel=132 ieee80211n=1 'ht_capab=[HT20]'
expect_no_key '132 (5660 MHz), width: 160 MHz' ieee80211ac vht_oper_chwidth vht_oper_centr_freq_seg0_idx

# The 5 GHz grid as hostapd 2.12 lays it out: its own 80 MHz table for an
# unset seg0, and the 160 MHz blocks 36-64, 100-128 and 149-177.
grid_seg0() {
  local channel="$1" width="$2" block blocks
  if [[ "$width" == 80 ]]; then
    blocks="48:42 64:58 112:106 128:122 144:138 161:155 177:171"
  else
    blocks="64:50 128:114 177:163"
  fi
  for block in $blocks; do
    if ((channel <= ${block%:*})); then
      echo "${block#*:}"
      return
    fi
  done
}

# Every grid primary must render the same hostapd.conf with or without
# center1, and pass hostapd 2.12's checks: seg0 within the coupling distance
# (+-2/+-6 at 80 MHz, up to +-14 at 160 MHz) and the HT40 direction from
# allowed_ht40_channel_pair, which allows HT40+ only on these primaries.
ht40_plus_primaries=" 36 44 52 60 100 108 116 124 132 140 149 157 165 173 "
for width in 80 160; do
  for channel in $(seq 36 4 64) $(seq 100 4 144) $(seq 149 4 177); do
    if [[ "$width" == 160 && "$channel" -ge 132 && "$channel" -le 144 ]]; then
      continue
    fi
    seg0="$(grid_seg0 "$channel" "$width")"
    link="$channel ($((5000 + channel * 5)) MHz), width: $width MHz"
    if [[ "$(hostapd_conf_for "$link")" != "$(hostapd_conf_for "$link, center1: $((5000 + seg0 * 5)) MHz")" ]]; then
      echo "station '$link': hostapd.conf differs without center1" >&2
      exit 1
    fi
    distance=$((seg0 > channel ? seg0 - channel : channel - seg0))
    if ((distance % 4 != 2 || distance > (width / 2 - 10) / 5)); then
      echo "station '$link': seg0 $seg0 fails hostapd's HT/VHT coupling check" >&2
      exit 1
    fi
    if [[ "$ht40_plus_primaries" == *" $channel "* ]]; then
      ht='ht_capab=[HT40+]'
    else
      ht='ht_capab=[HT40-]'
    fi
    expect_conf "$link" ieee80211n=1 ieee80211ac=1 "$ht" \
      "vht_oper_chwidth=$((width / 80))" "vht_oper_centr_freq_seg0_idx=$seg0"
    expect_no_key "$link" vht_oper_centr_freq_seg1_idx
  done
done

# A 20 MHz station must not enable VHT.
expect_no_key '9 (2452 MHz), width: 20 MHz, center1: 2452 MHz' ieee80211ac vht_oper_chwidth
# Upstream hostapd rejects unknown keys, and noscan exists only in OpenWrt.
if grep -q 'noscan=' "$helper"; then
  echo "hostapd.conf must not use the OpenWrt-only noscan option" >&2
  exit 1
fi

echo "hardware capability guard tests passed"
