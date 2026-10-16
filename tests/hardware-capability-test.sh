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
  (
    eval "$(awk '/^(station_channel|station_width|station_center_offset|station_vht_center|ht40_in_block|write_hostapd_conf)[(][)] [{]$/,/^}$/' "$helper")"
    # shellcheck disable=SC2034 # Read by the evaluated write_hostapd_conf.
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
expect_conf '104 (5520 MHz), width: 160 MHz, center1: 5570 MHz' \
  channel=104 ieee80211n=1 ieee80211ac=1 'ht_capab=[HT40-]' \
  vht_oper_chwidth=2 vht_oper_centr_freq_seg0_idx=114

if grep -q '^ieee80211ac=' <<<"$(hostapd_conf_for '9 (2452 MHz), width: 20 MHz, center1: 2452 MHz')"; then
  echo "a 20 MHz station must not enable VHT" >&2
  exit 1
fi
# Upstream hostapd rejects unknown keys, and noscan exists only in OpenWrt.
if grep -q 'noscan=' "$helper"; then
  echo "hostapd.conf must not use the OpenWrt-only noscan option" >&2
  exit 1
fi

echo "hardware capability guard tests passed"
