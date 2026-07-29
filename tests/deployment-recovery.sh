#!/usr/bin/env bash

# The mocked curl functions are exported to child scripts; each test is intentionally isolated.
# shellcheck disable=SC2030,SC2031,SC2329

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)

test_poll_reconnects() (
  STATE_PATH="${TEST_DIR}/poll-state"
  OUTPUT_PATH="${TEST_DIR}/poll-output"
  LOG_PATH="${TEST_DIR}/poll-log"
  printf 0 >"$STATE_PATH"
  export STATE_PATH

  curl() {
    local count
    count=$(<"$STATE_PATH")
    count=$((count + 1))
    printf '%s' "$count" >"$STATE_PATH"

    case "$count" in
      1) return 28 ;;
      2) printf '{"status":"pending"}\n200' ;;
      *) printf '{"status":"successful"}\n200' ;;
    esac
  }
  export -f curl

  export AWX_JOB_ID=123
  export AWX_USERNAME=user
  export AWX_PASSWORD=pass
  export GITHUB_OUTPUT="$OUTPUT_PATH"
  export AWX_POLL_TIMEOUT=8
  export AWX_POLL_INTERVAL=1
  export VPN_CONNECT_SCRIPT=/dev/null

  bash "${ROOT_DIR}/actions/_shared/poll-awx-job.sh" >"$LOG_PATH"
  grep -q "reconnecting the VPN" "$LOG_PATH"
  grep -q "job-status=success" "$OUTPUT_PATH"
)

test_launch_recovers_matching_job() (
  STATE_PATH="${TEST_DIR}/launch-state"
  OUTPUT_PATH="${TEST_DIR}/launch-output"
  LOG_PATH="${TEST_DIR}/launch-log"
  printf 0 >"$STATE_PATH"
  export STATE_PATH

  curl() {
    local count
    count=$(<"$STATE_PATH")
    count=$((count + 1))
    printf '%s' "$count" >"$STATE_PATH"

    if [[ "$count" == 1 ]]; then
      return 28
    fi

    printf '%s' '{"results":[{"id":456,"extra_vars":"{\"deploy_env\":\"uat\",\"deploy_image_tag\":\"v12\",\"docker_image\":\"ghcr.io/x/app:v12\",\"time_bypass\":\"false\"}"}]}'
  }
  export -f curl

  export AWX_TEMPLATE_ID=9
  export AWX_USERNAME=user
  export AWX_PASSWORD=pass
  export GITHUB_OUTPUT="$OUTPUT_PATH"
  export AWX_EXTRA_VARS='{"deploy_env":"uat","deploy_image_tag":"v12","docker_image":"ghcr.io/x/app:v12","time_bypass":"false"}'
  export AWX_MATCH_VARS='{"deploy_env":"uat","deploy_image_tag":"v12","docker_image":"ghcr.io/x/app:v12"}'
  export VPN_CONNECT_SCRIPT=/dev/null
  export AWX_LAUNCH_RECOVERY_TIMEOUT=8

  bash "${ROOT_DIR}/actions/_shared/launch-awx-job.sh" >"$LOG_PATH"
  grep -q "Recovered AWX job 456" "$LOG_PATH"
  grep -q "job-id=456" "$OUTPUT_PATH"
)

test_poll_reconnects
test_launch_recovers_matching_job
