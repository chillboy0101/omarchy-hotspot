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

# ap0's address comes from ap_mac_for, which must keep it locally
# administered, unicast and apart from the station's own address: mac80211
# refuses to bring up a duplicate ("Name not unique on network") and the
# RTL8723DE firmware rejects one. It must be the same on every start.
ensure_vif_body="$(awk '/^ensure_vif[(][)] [{]$/,/^}$/' "$helper")"
# shellcheck disable=SC2016 # Verify the literal command substitution in the helper.
grep -qF 'if ! ap_mac="$(ap_mac_for "$station_mac")"; then' <<<"$ensure_vif_body"
if grep -qF 'ap_mac="02' <<<"$ensure_vif_body"; then
  echo "ensure_vif must derive the ap0 address with ap_mac_for" >&2
  exit 1
fi
(
  eval "$(awk '/^ap_mac_for[(][)] [{]$/,/^}$/' "$helper")"

  expect_ap_mac() {
    local station="$1" expected="$2" actual
    actual="$(ap_mac_for "$station" || true)"
    if [[ "$actual" != "$expected" ]]; then
      echo "station $station: ap0 address '$actual', expected '$expected'" >&2
      exit 1
    fi
  }
  # A globally administered station keeps the address earlier releases used.
  expect_ap_mac 00:e0:4c:12:34:56 02:e0:4c:12:34:56
  expect_ap_mac A4:5E:60:C1:D2:E3 02:5e:60:c1:d2:e3
  # Randomized (locally administered) station addresses, as NetworkManager
  # makes them. Only one that starts with 02 needs the further bit.
  expect_ap_mac 3a:7f:11:22:33:44 02:7f:11:22:33:44
  expect_ap_mac 06:11:22:33:44:55 02:11:22:33:44:55
  expect_ap_mac 02:5c:9a:0b:7e:21 06:5c:9a:0b:7e:21
  expect_ap_mac 02:AB:CD:EF:01:23 06:ab:cd:ef:01:23
  # mac80211_hwsim radios are 02:00:00:00:NN:00.
  expect_ap_mac 02:00:00:00:00:00 06:00:00:00:00:00
  expect_ap_mac 02:00:00:00:01:00 06:00:00:00:01:00

  # Every first octet, with two different tails.
  for tail in 00:00:00:00:00 e0:4c:68:02:9f; do
    for ((octet = 0; octet < 256; octet++)); do
      station="$(printf '%02x' "$octet"):$tail"
      ap="$(ap_mac_for "$station")"
      first=$((16#${ap:0:2}))
      if ((first & 1)) || ! ((first & 2)) || [[ "$ap" == "$station" ]] \
        || [[ "${ap:2}" != ":$tail" || "$(ap_mac_for "$station")" != "$ap" ]]; then
        echo "station $station: ap0 address '$ap' is not a stable, distinct, locally administered unicast address" >&2
        exit 1
      fi
    done
  done

  # Anything but six octets is refused, so ensure_vif sets no address.
  for station in '' 00:e0:4c:12:34 00:e0:4c:12:34:56:78 zz:e0:4c:12:34:56 00-e0-4c-12-34-56 \
    $'00:e0:4c:12:34:56\n'; do
    if ap="$(ap_mac_for "$station")" || [[ -n "$ap" ]]; then
      echo "station '$station': ap_mac_for must refuse a malformed address" >&2
      exit 1
    fi
  done
)

if grep -q "ip link set \"\$VIF\" up" "$helper"; then
  echo "startup must let hostapd bring the AP interface up" >&2
  exit 1
fi

grep -q "hostapd_cli -p /run/hostapd -i \"\$VIF\" status" "$helper"
grep -q "grep -qx 'state=ENABLED'" "$helper"
wait_line="$(grep -n 'wait_for_hostapd' "$helper" | head -1 | cut -d: -f1)"
dns_line="$(grep -n 'systemd-run --unit=omarchy-hotspot-dns' "$helper" | head -1 | cut -d: -f1)"
[[ "$wait_line" -lt "$dns_line" ]]

# `iw phy <phy> info` as iw 6.17 prints it for a 2.4/5/6 GHz radio. The 2.4
# and 5 GHz channels in $radar, $no_ir and $disabled carry those flags, and
# those in $absent are left out. 6 GHz reuses the 2.4 and 5 GHz channel
# numbers: as in ETSI countries, 1-93 are usable and the rest disabled, so a
# lookup by number would let 6 GHz [13] pass a no-IR 2.4 GHz ch13 and 6 GHz
# [149] fail ch149. The bitrate and interface combination lines are there to
# show that they are not channels.
phy_info() {
  local channel freq flags
  printf 'Wiphy phy0\n\tBand 1:\n\t\tBitrates (non-HT):\n\t\t\t* 1.0 Mbps\n\t\tFrequencies:\n'
  for channel in $(seq 1 14) BAND $(seq 36 4 64) $(seq 100 4 144) $(seq 149 4 177); do
    if [[ "$channel" == BAND ]]; then
      printf '\tBand 2:\n\t\tFrequencies:\n'
      continue
    fi
    [[ " ${absent:-} " != *" $channel "* ]] || continue
    if ((channel == 14)); then
      freq=2484
    elif ((channel < 14)); then
      freq=$((2412 + (channel - 1) * 5))
    else
      freq=$((5000 + channel * 5))
    fi
    flags=" (24.0 dBm)"
    if [[ " ${disabled:-} " == *" $channel "* ]]; then
      flags=" (disabled)"
    elif [[ " ${radar:-} " == *" $channel "* ]]; then
      flags+=" (radar detection)"
      # Some regulatory domains also forbid initiating radiation there.
      [[ "$channel" != 140 ]] || flags=" (24.0 dBm) (no IR, radar detection)"
    elif [[ " ${no_ir:-} " == *" $channel "* ]]; then
      flags+=" (no IR)"
    fi
    printf '\t\t\t* %d.0 MHz [%d]%s\n' "$freq" "$channel" "$flags"
  done
  printf '\tBand 4:\n\t\tFrequencies:\n'
  for channel in $(seq 1 4 233); do
    flags=" (23.0 dBm)"
    ((channel <= 93)) || flags=" (disabled)"
    printf '\t\t\t* %d.0 MHz [%d]%s\n' $((5950 + channel * 5)) "$channel" "$flags"
  done
  printf '\tvalid interface combinations:\n'
  printf '\t\t * #{ managed } <= 1, #{ AP } <= 1,\n'
  printf '\t\t   total <= 2, #channels <= 1, radar detect widths: { 20 MHz (no HT), 20 MHz }\n'
}

# Render hostapd.conf with the helper's own functions for a station link as
# `iw dev <station> info` prints it, e.g. "9 (2452 MHz), width: 20 MHz, ...".
# Set $radar, $no_ir, $disabled and $absent to flag channels as phy_info does.
hostapd_conf_for() {
  local link="$1"
  # shellcheck disable=SC2034,SC2329 # The evaluated helper functions use these stubs.
  (
    eval "$(awk '/^(station_channel|station_freq|station_width|station_center_offset|station_vht_center|ht40_in_block|vht_block_center|channel_states|block_usable|write_hostapd_conf)[(][)] [{]$/,/^}$/' "$helper")"
    VIF=ap0 BLOCKED_FILE=/dev/null
    station_iface() { echo wlo1; }
    iw() {
      if [[ "$1" == phy* ]]; then
        [[ "$1" == 'phy#0' && -z "${phy_unreadable:-}" ]] || return 1
        phy_info
      else
        # iw prints the SSID, when the kernel reports one, before wiphy and
        # channel.
        printf '\tssid my wiphy channel 5\n\ttype managed\n\twiphy 0\n\tchannel %s\n' "$link"
      fi
    }
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

# Radar (DFS) channels as GH (DFS-FCC) marks them: 52-64 and 100-144. Every
# 160 MHz block there holds some. The AP keeps the station's primary and
# narrows to the widest block around it without a radar channel, so it never
# needs ieee80211h, a country_code (which hostapd sends to the kernel as a
# regulatory hint) or a channel availability check.
gh_radar="52 56 60 64 $(seq -s ' ' 100 4 144)"
radar="$gh_radar" expect_conf '36 (5180 MHz), width: 160 MHz, center1: 5250 MHz' \
  channel=36 ieee80211n=1 ieee80211ac=1 'ht_capab=[HT40+]' \
  vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42
radar="$gh_radar" expect_conf '48 (5240 MHz), width: 160 MHz' \
  channel=48 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42
radar="$gh_radar" expect_conf '44 (5220 MHz), width: 160 MHz, center1: 5250 MHz' \
  channel=44 ieee80211ac=1 'ht_capab=[HT40+]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42
# Blocks without a radar channel stay as they are.
radar="$gh_radar" expect_conf '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
  channel=36 ieee80211ac=1 'ht_capab=[HT40+]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42
radar="$gh_radar" expect_conf '161 (5805 MHz), width: 80 MHz, center1: 5775 MHz' \
  channel=161 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=155
radar="$gh_radar" expect_conf '44 (5220 MHz), width: 40 MHz, center1: 5230 MHz' \
  channel=44 'ht_capab=[HT40+]'
for link in '36 (5180 MHz), width: 160 MHz, center1: 5250 MHz' \
  '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' '149 (5745 MHz), width: 20 MHz'; do
  radar="$gh_radar" expect_no_key "$link" ieee80211h ieee80211d country_code
done
# A radio whose channel flags cannot be read keeps the station's width, as
# before the radar check existed.
phy_unreadable=1 radar="$gh_radar" expect_conf '36 (5180 MHz), width: 160 MHz, center1: 5250 MHz' \
  channel=36 ieee80211ac=1 'ht_capab=[HT40+]' vht_oper_chwidth=2 vht_oper_centr_freq_seg0_idx=50
# Narrowing continues through 40 and 20 MHz when the radar channel is closer.
radar=44 expect_conf '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
  channel=36 ieee80211n=1 'ht_capab=[HT40+]'
radar=44 expect_no_key '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
  ieee80211ac vht_oper_chwidth vht_oper_centr_freq_seg0_idx
radar=40 expect_conf '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' channel=36 'ht_capab=[HT20]'
radar=40 expect_conf '36 (5180 MHz), width: 40 MHz, center1: 5190 MHz' channel=36 'ht_capab=[HT20]'
radar=36 expect_conf '40 (5200 MHz), width: 40 MHz, center1: 5190 MHz' channel=40 'ht_capab=[HT20]'

# hostapd 2.12 also disables channels marked "disabled" or "no IR" for an AP,
# and a channel the radio does not list fails like a disabled one. GH
# disables 169-177, so the 160 MHz block 149-177 narrows to 80 MHz, and
# ch165, whose 80 and 40 MHz blocks hold 169, to 20 MHz.
gh_disabled="169 173 177"
disabled="$gh_disabled" expect_conf '149 (5745 MHz), width: 160 MHz, center1: 5815 MHz' \
  channel=149 ieee80211n=1 ieee80211ac=1 'ht_capab=[HT40+]' \
  vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=155
disabled="$gh_disabled" expect_conf '161 (5805 MHz), width: 160 MHz' \
  channel=161 ieee80211ac=1 'ht_capab=[HT40-]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=155
disabled="$gh_disabled" expect_conf '165 (5825 MHz), width: 160 MHz, center1: 5815 MHz' \
  channel=165 ieee80211n=1 'ht_capab=[HT20]'
disabled="$gh_disabled" expect_no_key '165 (5825 MHz), width: 160 MHz, center1: 5815 MHz' \
  ieee80211ac vht_oper_chwidth vht_oper_centr_freq_seg0_idx
no_ir="44 48" expect_conf '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
  channel=36 ieee80211n=1 'ht_capab=[HT40+]'
no_ir="44 48" expect_no_key '36 (5180 MHz), width: 80 MHz, center1: 5210 MHz' \
  ieee80211ac vht_oper_chwidth vht_oper_centr_freq_seg0_idx
# 2.4 GHz too: the world regulatory domain marks 12 and 13 no IR.
no_ir="12 13" expect_conf '9 (2452 MHz), width: 40 MHz, center1: 2462 MHz' \
  hw_mode=g channel=9 ieee80211n=1 'ht_capab=[HT20]'
# mac80211_hwsim, for one, has no channel 144.
absent=144 expect_conf '136 (5680 MHz), width: 80 MHz, center1: 5690 MHz' \
  channel=136 ieee80211n=1 'ht_capab=[HT40-]'
absent=144 expect_no_key '136 (5680 MHz), width: 80 MHz, center1: 5690 MHz' \
  ieee80211ac vht_oper_chwidth vht_oper_centr_freq_seg0_idx
# The disabled 6 GHz [149] must not touch 5 GHz ch149 (and the usable 6 GHz
# [13] must not rescue ch13 above).
expect_conf '149 (5745 MHz), width: 80 MHz, center1: 5775 MHz' \
  channel=149 ieee80211ac=1 'ht_capab=[HT40+]' vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=155

# A primary that hostapd refuses leaves nothing to narrow to. The helper must
# refuse before writing hostapd.conf, with a reason that contains TEXT and
# fits the panel's 120-character error line.
expect_refusal() {
  local link="$1" text="$2" conf message
  if conf="$(hostapd_conf_for "$link" 2>/dev/null)" || [[ -n "$conf" ]]; then
    echo "station '$link': hostapd.conf must not be written on an unusable primary" >&2
    exit 1
  fi
  message="$(hostapd_conf_for "$link" 2>&1 >/dev/null || true)"
  if [[ "$message" != *"$text"* || ${#message} -gt 120 ]]; then
    echo "station '$link': unclear refusal '$message'" >&2
    exit 1
  fi
}
expect_dfs_refusal() {
  radar="$gh_radar" expect_refusal "$1" "radar (DFS) channel ${1%% *},"
}
no_ir="149 153 157 161 165" expect_refusal '149 (5745 MHz), width: 80 MHz, center1: 5775 MHz' \
  'channel 149, where regulatory rules forbid starting an access point (no IR).'
no_ir="12 13" expect_refusal '13 (2472 MHz), width: 20 MHz' \
  'channel 13, where regulatory rules forbid starting an access point (no IR).'
disabled="$gh_disabled" expect_refusal '169 (5845 MHz), width: 20 MHz' \
  'channel 169, which this radio cannot use for an access point.'
absent=144 expect_refusal '144 (5720 MHz), width: 20 MHz' \
  'channel 144, which this radio cannot use for an access point.'
# Channel 14 is 2484 MHz, off the 5 MHz spacing of 1-13. Japan enables it;
# GH disables it.
expect_conf '14 (2484 MHz), width: 20 MHz' hw_mode=g channel=14 'ht_capab=[HT20]'
disabled=14 expect_refusal '14 (2484 MHz), width: 20 MHz' \
  'channel 14, which this radio cannot use for an access point.'
expect_dfs_refusal '100 (5500 MHz), width: 20 MHz'
expect_dfs_refusal '52 (5260 MHz), width: 80 MHz, center1: 5290 MHz'
expect_dfs_refusal '64 (5320 MHz), width: 40 MHz, center1: 5310 MHz'
expect_dfs_refusal '104 (5520 MHz), width: 160 MHz, center1: 5570 MHz'
# Channel 140 is no IR as well as radar; the radar reason names the fix.
expect_dfs_refusal '140 (5700 MHz), width: 40 MHz'
# 6 GHz reuses the 2.4 and 5 GHz channel numbers, so the band comes from the
# frequency iw prints. hostapd 2.12 needs SAE and op_class for a 6 GHz AP,
# and the hotspot serves WPA2-PSK, so it refuses any 6 GHz station, usable
# channel or not. 6 GHz [5] must not pass as 2.4 GHz ch5 (hw_mode=g), nor
# [37] and [149] as 5 GHz ch37 and ch149 (hw_mode=a).
expect_refusal '37 (6135 MHz), width: 160 MHz, center1: 6185 MHz' \
  'Wi-Fi uses 6 GHz channel 37, which this hotspot cannot share. Connect to a 2.4 or 5 GHz network.'
expect_refusal '5 (5975 MHz), width: 20 MHz' 'Wi-Fi uses 6 GHz channel 5,'
expect_refusal '149 (6695 MHz), width: 80 MHz, center1: 6705 MHz' 'Wi-Fi uses 6 GHz channel 149,'
# Channel 2 (5935 MHz) is the lowest 6 GHz channel, below [1] at 5955 MHz.
expect_refusal '2 (5935 MHz), width: 20 MHz' 'Wi-Fi uses 6 GHz channel 2,'
phy_unreadable=1 expect_refusal '37 (6135 MHz), width: 160 MHz, center1: 6185 MHz' \
  'Wi-Fi uses 6 GHz channel 37,'
# The highest 5 GHz channel stays 5 GHz.
expect_conf '177 (5885 MHz), width: 20 MHz' hw_mode=a channel=177 'ht_capab=[HT20]'

# start_ap renders hostapd.conf before it creates ap0, so a refusal leaves no
# interface behind.
start_ap_body="$(awk '/^start_ap[(][)] [{]$/,/^}$/' "$helper")"
render_line="$(grep -n '^  write_hostapd_conf$' <<<"$start_ap_body" | cut -d: -f1)"
vif_line="$(grep -n '^  ensure_vif$' <<<"$start_ap_body" | cut -d: -f1)"
[[ -n "$render_line" && -n "$vif_line" && "$render_line" -lt "$vif_line" ]]

# A 20 MHz station must not enable VHT.
expect_no_key '9 (2452 MHz), width: 20 MHz, center1: 2452 MHz' ieee80211ac vht_oper_chwidth
# Upstream hostapd rejects unknown keys, and noscan exists only in OpenWrt.
if grep -q 'noscan=' "$helper"; then
  echo "hostapd.conf must not use the OpenWrt-only noscan option" >&2
  exit 1
fi

echo "hardware capability guard tests passed"
