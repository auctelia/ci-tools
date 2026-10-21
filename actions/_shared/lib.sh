#!/usr/bin/env bash

# Helpers shared by the deploy and migrate scripts to turn opaque network failures into reasons.

VPN_LOG_PATH="${VPN_LOG_PATH:-${RUNNER_TEMP:-/tmp}/openvpn.log}"

# How many times the VPN server reset the current session (another job took the shared certificate).
vpn_session_resets() {
  sudo cat "$VPN_LOG_PATH" 2>/dev/null | grep -c "Connection reset, restarting"
}

vpn_contention_note() {
  if (($(vpn_session_resets) > 0)); then
    echo " The VPN server reset this session $(vpn_session_resets)×: another job was connected with the same shared VPN certificate (fixed server-side by duplicate-cn, auctelia/Infrastructure#69)."
  fi
}

curl_reason() {
  case "$1" in
    6) echo "the AWX host name did not resolve" ;;
    7) echo "AWX refused the connection or is unreachable" ;;
    28) echo "AWX did not answer in time through the VPN" ;;
    35 | 52 | 56) echo "the connection to AWX was cut (VPN session dropped)" ;;
    *) echo "curl failed with exit code $1" ;;
  esac
}
