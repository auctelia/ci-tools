#!/usr/bin/env bash

set -euo pipefail

: "${AWX_JOB_ID:?AWX_JOB_ID is required}"
: "${AWX_USERNAME:?AWX_USERNAME is required}"
: "${AWX_PASSWORD:?AWX_PASSWORD is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

AWX_BASE_URL="${AWX_BASE_URL:-http://ansible.cluster.auctelia.com/api/v2}"
OUTPUT_NAME="${AWX_STATUS_OUTPUT:-job-status}"
TIMEOUT="${AWX_POLL_TIMEOUT:-900}"
INTERVAL="${AWX_POLL_INTERVAL:-10}"
VPN_CONNECT_SCRIPT="${VPN_CONNECT_SCRIPT:-}"
VPN_CONFIG_PATH="${VPN_CONFIG_PATH:-vpn.conf}"
DEADLINE=$((SECONDS + TIMEOUT))

recover_vpn() {
  if [[ -z "$VPN_CONNECT_SCRIPT" ]]; then
    return 1
  fi

  echo "AWX became unreachable; reconnecting the VPN"
  bash "$VPN_CONNECT_SCRIPT" "$VPN_CONFIG_PATH"
}

read_status() {
  local response
  local http_status
  local body

  response=$(curl -sS \
    --max-time 30 \
    --connect-timeout 10 \
    -w $'\n%{http_code}' \
    -u "${AWX_USERNAME}:${AWX_PASSWORD}" \
    "${AWX_BASE_URL}/jobs/${AWX_JOB_ID}/") || return 1

  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "$http_status" =~ ^(400|401|403|404)$ ]]; then
    echo "AWX returned non-retryable HTTP ${http_status} for job ${AWX_JOB_ID}" >&2
    return 2
  fi

  [[ "$http_status" =~ ^2[0-9][0-9]$ ]] || return 1

  jq -er '.status | select(type == "string")' <<<"$body"
}

echo "Waiting for AWX job ${AWX_JOB_ID}"

while ((SECONDS < DEADLINE)); do
  if STATUS=$(read_status); then
    :
  else
    READ_EXIT=$?
    if [[ "$READ_EXIT" == 2 ]]; then
      echo "${OUTPUT_NAME}=unknown" >>"$GITHUB_OUTPUT"
      exit 1
    fi

    recover_vpn || echo "VPN reconnection failed; retrying before the deadline" >&2
    sleep "$INTERVAL"
    continue
  fi

  echo "AWX job ${AWX_JOB_ID}: ${STATUS}"

  case "$STATUS" in
    successful)
      echo "${OUTPUT_NAME}=success" >>"$GITHUB_OUTPUT"
      exit 0
      ;;
    failed | error | canceled)
      echo "${OUTPUT_NAME}=failed" >>"$GITHUB_OUTPUT"
      exit 1
      ;;
    new | pending | waiting | running)
      sleep "$INTERVAL"
      ;;
    *)
      echo "Unknown AWX status '${STATUS}'; polling again" >&2
      sleep "$INTERVAL"
      ;;
  esac
done

echo "${OUTPUT_NAME}=unknown" >>"$GITHUB_OUTPUT"
echo "AWX job ${AWX_JOB_ID} did not reach a terminal state within ${TIMEOUT}s" >&2
exit 1
