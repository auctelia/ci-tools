#!/usr/bin/env bash

set -euo pipefail

: "${AWX_TEMPLATE_ID:?AWX_TEMPLATE_ID is required}"
: "${AWX_USERNAME:?AWX_USERNAME is required}"
: "${AWX_PASSWORD:?AWX_PASSWORD is required}"
: "${AWX_EXTRA_VARS:?AWX_EXTRA_VARS is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

AWX_BASE_URL="${AWX_BASE_URL:-http://ansible.cluster.auctelia.com/api/v2}"
OUTPUT_NAME="${AWX_JOB_OUTPUT:-job-id}"
RECOVERY_TIMEOUT="${AWX_LAUNCH_RECOVERY_TIMEOUT:-60}"
MATCH_VARS="${AWX_MATCH_VARS:-$AWX_EXTRA_VARS}"
VPN_CONNECT_SCRIPT="${VPN_CONNECT_SCRIPT:-}"
VPN_CONFIG_PATH="${VPN_CONFIG_PATH:-vpn.conf}"
PAYLOAD=$(jq -nc --argjson extra_vars "$AWX_EXTRA_VARS" '{extra_vars: $extra_vars}')

recover_vpn() {
  if [[ -n "$VPN_CONNECT_SCRIPT" ]]; then
    bash "$VPN_CONNECT_SCRIPT" "$VPN_CONFIG_PATH"
  fi
}

find_matching_job() {
  local response

  response=$(curl -sS \
    --max-time 30 \
    --connect-timeout 10 \
    -u "${AWX_USERNAME}:${AWX_PASSWORD}" \
    "${AWX_BASE_URL}/job_templates/${AWX_TEMPLATE_ID}/jobs/?order_by=-created&page_size=20") || return 1

  jq -er --argjson expected "$MATCH_VARS" '
    def job_vars:
      if (.extra_vars | type) == "string"
      then (.extra_vars | fromjson? // {})
      else (.extra_vars // {})
      end;

    first(
      .results[]
      | job_vars as $actual
      | select($expected | to_entries | all(.[]; $actual[.key] == .value))
      | .id
    )
  ' <<<"$response"
}

HTTP_RESPONSE=""
if HTTP_RESPONSE=$(curl -sS \
  --max-time 30 \
  --connect-timeout 10 \
  -w $'\n%{http_code}' \
  -X POST \
  "${AWX_BASE_URL}/job_templates/${AWX_TEMPLATE_ID}/launch/" \
  -H "Content-Type: application/json" \
  -u "${AWX_USERNAME}:${AWX_PASSWORD}" \
  -d "$PAYLOAD"); then
  HTTP_STATUS="${HTTP_RESPONSE##*$'\n'}"
  HTTP_BODY="${HTTP_RESPONSE%$'\n'*}"

  if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    JOB_ID=$(jq -r '.id // empty' <<<"$HTTP_BODY")
    if [[ -n "$JOB_ID" ]]; then
      echo "${OUTPUT_NAME}=${JOB_ID}" >>"$GITHUB_OUTPUT"
      echo "AWX job ${JOB_ID} started"
      exit 0
    fi
  elif [[ "$HTTP_STATUS" =~ ^4[0-9][0-9]$ ]]; then
    echo "AWX rejected the launch with HTTP ${HTTP_STATUS}: ${HTTP_BODY}" >&2
    exit 1
  fi
fi

echo "The launch response was lost; looking up the matching AWX job"
DEADLINE=$((SECONDS + RECOVERY_TIMEOUT))

while ((SECONDS < DEADLINE)); do
  recover_vpn || true

  if JOB_ID=$(find_matching_job); then
    echo "${OUTPUT_NAME}=${JOB_ID}" >>"$GITHUB_OUTPUT"
    echo "Recovered AWX job ${JOB_ID}"
    exit 0
  fi

  sleep 5
done

echo "Could not recover a matching AWX job after ${RECOVERY_TIMEOUT}s" >&2
exit 1
