#!/usr/bin/env bash

lease_hostname() {
  local mac="${1,,}" lease_file="$2"
  [ -r "$lease_file" ] || return 0
  awk -v wanted="$mac" 'tolower($2) == wanted && $4 != "*" { print $4; exit }' "$lease_file"
}

lease_ip() {
  local mac="${1,,}" lease_file="$2"
  [ -r "$lease_file" ] || return 0
  awk -v wanted="$mac" 'tolower($2) == wanted { print $3; exit }' "$lease_file"
}

mac_vendor() {
  local mac="${1^^}" oui_file="$2" first_octet oui
  first_octet="${mac%%:*}"
  [[ "$first_octet" =~ ^[0-9A-F]{2}$ ]] || return 0
  (( (16#$first_octet & 2) == 0 )) || return 0
  oui="${mac//:/}"
  oui="${oui:0:6}"
  [ -r "$oui_file" ] || return 0
  awk -v wanted="$oui" '$1 == wanted && $2 == "(base" && $3 == "16)" { $1=$2=$3=""; sub(/^[[:space:]]+/, ""); print; exit }' "$oui_file"
}

device_label() {
  local mac="$1" lease_file="$2" oui_file="$3" reverse_name="${4:-}" label
  label="$(lease_hostname "$mac" "$lease_file")"
  if [ -z "$label" ] && [ -n "$reverse_name" ]; then
    label="${reverse_name%.local}"
  fi
  if [ -z "$label" ]; then
    label="$(mac_vendor "$mac" "$oui_file")"
    [ -z "$label" ] || label="$label device"
  fi
  printf '%s\n' "${label:-Unknown device}" | tr -d '\t\r\n'
}

tsv_value() {
  local mac="${1,,}" file="$2" field="$3"
  [ -r "$file" ] || return 0
  awk -F '\t' -v wanted="$mac" -v field="$field" 'tolower($1) == wanted { print $field; exit }' "$file"
}

resolve_device() {
  local mac="${1,,}" ip="$2" metadata_file="$3" discovery_file="$4" aliases_file="$5" oui_file="$6"
  local label source discovery_ip

  label="$(tsv_value "$mac" "$aliases_file" 2)"
  source="alias"
  if [ -z "$label" ]; then
    label="$(tsv_value "$mac" "$metadata_file" 3)"
    source="dhcp"
  fi
  if [ -z "$label" ]; then
    discovery_ip="$(tsv_value "$mac" "$discovery_file" 2)"
    if [ "$discovery_ip" = "$ip" ]; then
      label="$(tsv_value "$mac" "$discovery_file" 3)"
      label="${label%.local}"
    fi
    source="mdns"
  fi
  if [ -z "$label" ] && [ "$discovery_ip" = "$ip" ]; then
    label="$(tsv_value "$mac" "$discovery_file" 4)"
    source="netbios"
  fi
  if [ -z "$label" ]; then
    label="$(mac_vendor "$mac" "$oui_file")"
    [ -z "$label" ] || label="$label device"
    source="vendor"
  fi
  if [ -z "$label" ]; then
    label="Unknown device"
    source="unknown"
  fi
  label="$(printf '%s' "$label" | LC_ALL=C tr -d '\000-\037\177')"
  printf '%s\t%s\n' "$label" "$source"
}

valid_mac() {
  [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

set_device_alias() {
  local mac="${1,,}" alias="$2" aliases_file="$3" length clean tmp
  valid_mac "$mac" || { echo "Invalid device address" >&2; return 1; }
  [ -n "$alias" ] || { echo "Device name cannot be empty" >&2; return 1; }
  printf '%s' "$alias" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || { echo "Device name must be valid UTF-8" >&2; return 1; }
  clean="$(printf '%s' "$alias" | LC_ALL=C tr -d '\000-\037\177')"
  [ "$clean" = "$alias" ] || { echo "Device name contains unsupported control characters" >&2; return 1; }
  length="$(printf '%s' "$alias" | wc -m)"
  [ "$length" -le 48 ] || { echo "Device name must be 48 characters or fewer" >&2; return 1; }
  mkdir -p "$(dirname "$aliases_file")"
  touch "$aliases_file"
  chmod 600 "$aliases_file"
  exec 8>"$aliases_file.lock"
  flock 8
  tmp="$(mktemp "${aliases_file}.XXXXXX")"
  awk -F '\t' -v wanted="$mac" 'tolower($1) != wanted' "$aliases_file" >"$tmp"
  printf '%s\t%s\n' "$mac" "$alias" >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$aliases_file"
}

remove_device_alias() {
  local mac="${1,,}" aliases_file="$2" tmp
  valid_mac "$mac" || { echo "Invalid device address" >&2; return 1; }
  [ -e "$aliases_file" ] || return 0
  exec 8>"$aliases_file.lock"
  flock 8
  tmp="$(mktemp "${aliases_file}.XXXXXX")"
  awk -F '\t' -v wanted="$mac" 'tolower($1) != wanted' "$aliases_file" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$aliases_file"
}

block_device() {
  local mac="${1,,}" label="$2" blocked_file="$3" tmp
  valid_mac "$mac" || { echo "Invalid device address" >&2; return 1; }
  label="$(printf '%s' "${label:-Unknown device}" | LC_ALL=C tr -d '\000-\037\177')"
  mkdir -p "$(dirname "$blocked_file")"
  touch "$blocked_file"
  chmod 600 "$blocked_file"
  exec 7>"$blocked_file.lock"
  flock 7
  tmp="$(mktemp "${blocked_file}.XXXXXX")"
  awk -F '\t' -v wanted="$mac" 'tolower($1) != wanted' "$blocked_file" >"$tmp"
  printf '%s\t%s\n' "$mac" "$label" >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$blocked_file"
}

unblock_device() {
  local mac="${1,,}" blocked_file="$2" tmp
  valid_mac "$mac" || { echo "Invalid device address" >&2; return 1; }
  [ -e "$blocked_file" ] || return 0
  exec 7>"$blocked_file.lock"
  flock 7
  tmp="$(mktemp "${blocked_file}.XXXXXX")"
  awk -F '\t' -v wanted="$mac" 'tolower($1) != wanted' "$blocked_file" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$blocked_file"
}
