#!/usr/bin/env bash

set -euo pipefail

VPN_CONFIG_PATH="${1:-vpn.conf}"
CONNECT_TIMEOUT="${VPN_CONNECT_TIMEOUT:-45}"
CONNECT_ATTEMPTS="${VPN_CONNECT_ATTEMPTS:-3}"
VPN_LOG_PATH="${VPN_LOG_PATH:-${RUNNER_TEMP:-/tmp}/openvpn.log}"

# tun0 is created before the handshake finishes and before pushed routes are installed, so the
# only trustworthy readiness signal is openvpn's own "Initialization Sequence Completed" line.
READY_LINE="Initialization Sequence Completed"

vpn_log() {
  sudo cat "$VPN_LOG_PATH" 2>/dev/null || true
}

explain_failure() {
  local log
  log=$(vpn_log)

  if grep -q "AUTH_FAILED" <<<"$log"; then
    echo "the VPN server rejected the client certificate (AUTH_FAILED); check the VPN_CLIENT_CERT/VPN_CLIENT_KEY org secrets"
  elif grep -qE "Cannot load (certificate|private key|CA)|PEM routines" <<<"$log"; then
    echo "openvpn could not load the certificates; a VPN_* org secret is malformed"
  elif grep -qE "TLS key negotiation failed|TLS handshake failed" <<<"$log"; then
    echo "the TLS handshake with the VPN server did not complete (server unreachable, or VPN_CA_CERT/VPN_TA_KEY mismatch)"
  elif grep -qE "Connection refused|Connection timed out|No route to host|Network is unreachable" <<<"$log"; then
    echo "the VPN server is unreachable: $(grep -m1 -oE 'remote [^ ]+ [0-9]+|\[AF_INET\][0-9.:]+' <<<"$log" || echo 'see the openvpn log')"
  elif grep -q "Exiting due to fatal error" <<<"$log"; then
    echo "openvpn exited: $(grep -B1 -m1 "Exiting due to fatal error" <<<"$log" | head -1 | cut -d' ' -f6-)"
  else
    echo "openvpn did not report '${READY_LINE}' within ${CONNECT_TIMEOUT}s"
  fi
}

stop_tunnel() {
  sudo pkill -x openvpn 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x openvpn >/dev/null 2>&1 || return 0
    sleep 1
  done
  sudo pkill -9 -x openvpn 2>/dev/null || true
}

start_tunnel() {
  stop_tunnel
  sudo rm -f "$VPN_LOG_PATH"
  sudo openvpn --config "$VPN_CONFIG_PATH" --daemon --log "$VPN_LOG_PATH" --verb 3
}

wait_for_tunnel() {
  local deadline=$((SECONDS + CONNECT_TIMEOUT))

  until vpn_log | grep -q "$READY_LINE"; do
    if ! pgrep -x openvpn >/dev/null 2>&1; then
      return 1
    fi
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 1
  done
}

for attempt in $(seq 1 "$CONNECT_ATTEMPTS"); do
  started=$SECONDS
  start_tunnel

  if wait_for_tunnel; then
    # The runner's eth0 subnet (10.1.0.0/20) overlaps the VPC, so it must stop shadowing the tunnel.
    sudo ip route del 10.1.0.0/20 dev eth0 2>/dev/null || true
    sudo ip route replace 10.0.0.0/16 dev tun0
    address=$(ip -4 addr show tun0 | awk '/inet /{print $2; exit}')
    echo "VPN tunnel is ready (tun0 ${address}, attempt ${attempt}/${CONNECT_ATTEMPTS}, $((SECONDS - started))s)"
    exit 0
  fi

  reason=$(explain_failure)
  echo "::warning title=VPN attempt ${attempt}/${CONNECT_ATTEMPTS} failed::${reason}"
done

stop_tunnel
echo "::group::openvpn log (last 40 lines)"
vpn_log | tail -40
echo "::endgroup::"
echo "::error title=VPN connection failed::${reason} (after ${CONNECT_ATTEMPTS} attempts)"
exit 1
