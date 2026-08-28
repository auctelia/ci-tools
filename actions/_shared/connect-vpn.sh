#!/usr/bin/env bash

set -euo pipefail

VPN_CONFIG_PATH="${1:-vpn.conf}"
CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-45}"
CONNECT_ATTEMPTS="${VPN_CONNECT_ATTEMPTS:-3}"

# The tunnel comes up unreliably from GitHub runners, and a single failed
# handshake used to fail the whole deployment. Retry the full cycle instead,
# and abandon an attempt as soon as the daemon dies rather than waiting out
# the timeout on a process that is already gone.

start_tunnel() {
  sudo pkill openvpn 2>/dev/null || true
  sleep 1
  sudo openvpn --config "$VPN_CONFIG_PATH" --daemon
}

tunnel_is_up() {
  # tun0 shows up before the handshake completes, so its mere existence proves
  # nothing: wait until it actually carries an address.
  ip -4 addr show tun0 2>/dev/null | grep -q 'inet '
}

wait_for_tunnel() {
  local deadline=$((SECONDS + CONNECT_TIMEOUT))

  while ! tunnel_is_up; do
    if ! pgrep -x openvpn >/dev/null 2>&1; then
      echo "openvpn a quitté avant l'établissement du tunnel" >&2
      return 1
    fi
    if ((SECONDS >= deadline)); then
      echo "le tunnel VPN (tun0) ne s'est pas établi en ${CONNECT_TIMEOUT}s" >&2
      return 1
    fi
    sleep 2
  done
}

connected=0
for attempt in $(seq 1 "$CONNECT_ATTEMPTS"); do
  echo "=== VPN : tentative ${attempt}/${CONNECT_ATTEMPTS} ==="
  start_tunnel

  if wait_for_tunnel; then
    connected=1
    break
  fi
done

if ((connected == 0)); then
  echo "Erreur: le tunnel VPN ne s'est pas établi après ${CONNECT_ATTEMPTS} tentatives de ${CONNECT_TIMEOUT}s" >&2
  exit 1
fi

# Let routing settle before rewriting it.
sleep 3
sudo ip route del 10.1.0.0/20 dev eth0 2>/dev/null || true
sudo ip route replace 10.0.0.0/16 dev tun0

echo "VPN tunnel is ready"
