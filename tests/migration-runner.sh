#!/usr/bin/env bash

# The mocked system commands are exported to the runner script; each test is intentionally isolated.
# shellcheck disable=SC2016,SC2030,SC2031,SC2329

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="${ROOT_DIR}/actions/_shared/run-migration.sh"
TEST_DIR=$(mktemp -d)

# A fake `npm run migrate`: prints the given gazeti lines for the current attempt, then exits with its code.
write_migrator() {
  local path="${TEST_DIR}/migrator-$1"
  shift
  {
    echo '#!/usr/bin/env bash'
    echo 'count=$(( $(cat "$ATTEMPTS_PATH" 2>/dev/null || echo 0) + 1 )); echo "$count" >"$ATTEMPTS_PATH"'
    echo 'case "$count" in'
    local index=1
    for script in "$@"; do
      echo "  ${index}) ${script} ;;"
      index=$((index + 1))
    done
    echo '  *) exit 99 ;;'
    echo 'esac'
  } >"$path"
  chmod +x "$path"
  echo "$path"
}

event() {
  printf "echo '{\"event\":{\"event\":\"%s\",\"name\":\"%s\"}}';" "$1" "$2"
}

failed_with() {
  printf "echo '{\"event\":\"MIGRATION\",\"indexed\":{\"message\":\"Migration failed\",\"error\":\"%s\"}}'; exit 1" "$1"
}

with_network() {
  export PG_HOST=db.internal PG_USER=user PG_PASSWORD=pass PG_DB=app PG_SSL=true
  export APP_NAME=items DEPLOY_ENV=integration
  export RUNNER_TEMP="${TEST_DIR}/$1"
  mkdir -p "$RUNNER_TEMP"
  export GITHUB_STEP_SUMMARY="${RUNNER_TEMP}/summary.md"
  export GITHUB_OUTPUT="${RUNNER_TEMP}/output"
  export ATTEMPTS_PATH="${RUNNER_TEMP}/attempts"
  export RECONNECTS_PATH="${RUNNER_TEMP}/reconnects"
  export MIGRATION_RETRY_DELAY=0
  export PG_IP="${PG_IP:-10.3.1.125}"

  getent() { echo "${PG_IP} STREAM db.internal"; }
  ip() { echo "${PG_IP} dev tun0 src 10.8.0.38 uid 1001"; }
  timeout() { return 0; }
  sudo() { return 1; }
  export -f getent ip timeout sudo

  VPN_CONNECT_SCRIPT="${RUNNER_TEMP}/reconnect.sh"
  printf '#!/usr/bin/env bash\necho reconnect >>"%s"\n' "$RECONNECTS_PATH" >"$VPN_CONNECT_SCRIPT"
  export VPN_CONNECT_SCRIPT
}

test_retries_a_reset_before_any_migration() (
  with_network reset-before
  MIGRATION_COMMAND=$(write_migrator reset-before \
    "$(failed_with 'read ECONNRESET')" \
    "$(event migrating 20261021-a.js) $(event migrated 20261021-a.js) exit 0")
  export MIGRATION_COMMAND

  bash "$RUNNER" >"${RUNNER_TEMP}/log"
  [[ "$(<"$ATTEMPTS_PATH")" == 2 ]]
  [[ "$(wc -l <"$RECONNECTS_PATH")" -eq 1 ]]
  grep -q "Succeeded on attempt 2/3" "$GITHUB_STEP_SUMMARY"
  grep -q '20261021-a.js' "$GITHUB_STEP_SUMMARY"
)

test_never_retries_a_reset_during_a_migration() (
  with_network reset-during
  MIGRATION_COMMAND=$(write_migrator reset-during \
    "$(event migrating 20261021-a.js) $(event migrated 20261021-a.js) $(event migrating 20261021-b.js) $(failed_with 'read ECONNRESET')")
  export MIGRATION_COMMAND

  if bash "$RUNNER" >"${RUNNER_TEMP}/log"; then return 1; fi
  [[ "$(<"$ATTEMPTS_PATH")" == 1 ]]
  grep -q "Failed at\*\* | Migration 20261021-b.js" "$GITHUB_STEP_SUMMARY"
  grep -q "partially applied" "$GITHUB_STEP_SUMMARY"
  grep -q "applied=20261021-a.js" "$GITHUB_OUTPUT"
)

test_does_not_retry_a_migration_bug() (
  with_network migration-bug
  MIGRATION_COMMAND=$(write_migrator migration-bug \
    "$(event migrating 20261021-a.js) $(failed_with 'Migration 20261021-a.js (up) failed: column \"x\" does not exist')")
  export MIGRATION_COMMAND

  if bash "$RUNNER" >"${RUNNER_TEMP}/log"; then return 1; fi
  [[ "$(<"$ATTEMPTS_PATH")" == 1 ]]
  grep -q "stage=Migration 20261021-a.js" "$GITHUB_OUTPUT"
  grep -q "not the network" "$GITHUB_STEP_SUMMARY"
)

test_rejects_a_public_database_address() (
  PG_IP=52.212.107.121
  with_network public-address
  MIGRATION_COMMAND=$(write_migrator public-address "exit 0")
  export MIGRATION_COMMAND

  if bash "$RUNNER" >"${RUNNER_TEMP}/log"; then return 1; fi
  [[ ! -f "$ATTEMPTS_PATH" ]]
  grep -q "public address 52.212.107.121" "$GITHUB_STEP_SUMMARY"
)

test_reports_missing_secrets_before_setup() (
  with_network missing-secrets
  unset PG_PASSWORD PG_DB

  if bash "$RUNNER" --check-secrets >"${RUNNER_TEMP}/log"; then return 1; fi
  grep -q "missing secrets: PG_PASSWORD PG_DB" "${RUNNER_TEMP}/log"
  grep -q "'integration' environment" "$GITHUB_STEP_SUMMARY"
)

test_steps_aside_when_another_job_holds_the_vpn() (
  with_network contention
  export MIGRATION_CONTENTION_DELAY=0 VPN_LOG_PATH="${RUNNER_TEMP}/openvpn.log"
  printf '%s\n' "Initialization Sequence Completed" "Connection reset, restarting [0]" >"$VPN_LOG_PATH"
  sudo() { [[ "$1" == cat ]] && command cat "$2"; }
  export -f sudo
  MIGRATION_COMMAND=$(write_migrator contention \
    "$(failed_with 'read ECONNRESET')" "$(failed_with 'read ECONNRESET')" "$(failed_with 'read ECONNRESET')")
  export MIGRATION_COMMAND

  if bash "$RUNNER" >"${RUNNER_TEMP}/log"; then return 1; fi
  [[ "$(<"$ATTEMPTS_PATH")" == 3 ]]
  grep -q "disconnecting for 0s so the other job can finish" "${RUNNER_TEMP}/log"
  grep -q "same VPN certificate" "$GITHUB_STEP_SUMMARY"
  grep -q "session reset" "$GITHUB_STEP_SUMMARY"
)

test_retries_a_reset_before_any_migration
test_steps_aside_when_another_job_holds_the_vpn
test_never_retries_a_reset_during_a_migration
test_does_not_retry_a_migration_bug
test_rejects_a_public_database_address
test_reports_missing_secrets_before_setup
echo "migration runner tests passed"
