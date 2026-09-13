#!/usr/bin/bash

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
