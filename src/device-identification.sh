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
