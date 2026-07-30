#!/usr/bin/env bash

set -euo pipefail

VPN_CONFIG_PATH="${1:-vpn.conf}"
CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-30}"

sudo pkill openvpn 2>/dev/null || true
sudo openvpn --config "$VPN_CONFIG_PATH" --daemon

DEADLINE=$((SECONDS + CONNECT_TIMEOUT))
while ! ip link show tun0 >/dev/null 2>&1; do
  if ((SECONDS >= DEADLINE)); then
    echo "VPN tunnel did not connect within ${CONNECT_TIMEOUT}s" >&2
    exit 1
  fi

  sleep 2
done

sleep 3
sudo ip route del 10.1.0.0/20 dev eth0 2>/dev/null || true
sudo ip route replace 10.0.0.0/16 dev tun0

echo "VPN tunnel is ready"
