#!/usr/bin/env bash

set -euo pipefail

: "${VPN_CONFIG:?VPN_CONFIG is required}"

if [[ -n "${VPN_CLIENT_CERT:-}" || -n "${VPN_CLIENT_KEY:-}" ]]; then
  : "${VPN_CLIENT_CERT:?VPN_CLIENT_CERT and VPN_CLIENT_KEY must be provided together}"
  : "${VPN_CLIENT_KEY:?VPN_CLIENT_CERT and VPN_CLIENT_KEY must be provided together}"
fi

umask 077
printf '%s\n' "$VPN_CONFIG" >vpn.conf

# Clamp TCP MSS so TLS handshake packets (larger than plain Postgres traffic) never exceed
# the tunnel's effective MTU. Without this, oversized packets get silently dropped whenever
# path MTU discovery is blackholed, hanging the connection for minutes before an ECONNRESET.
printf '%s\n' "mssfix 1400" >>vpn.conf

if [[ -n "${VPN_CLIENT_CERT:-}" ]]; then
  printf '%s\n' "$VPN_CLIENT_CERT" >github.crt
  printf '%s\n' "$VPN_CLIENT_KEY" >github.key
  printf '%s\n' "cert github.crt" "key github.key" >>vpn.conf
fi

if [[ -n "${VPN_CA_CERT:-}" ]]; then
  printf '%s\n' "$VPN_CA_CERT" >ca.crt
  printf '%s\n' "ca ca.crt" >>vpn.conf
fi

if [[ -n "${VPN_TA_KEY:-}" ]]; then
  printf '%s\n' "$VPN_TA_KEY" >ta.key
  printf '%s\n' "tls-auth ta.key 1" >>vpn.conf
fi

echo "VPN configuration is ready"
