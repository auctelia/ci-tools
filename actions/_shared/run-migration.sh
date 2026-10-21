#!/usr/bin/env bash

# Runs the repository's migrations through the VPN and, when it fails, says which stage failed and
# why: the database endpoint, the tunnel, the TLS handshake, the credentials or one named migration.
# Network failures that happen before any migration started are retried on a fresh tunnel; a failure
# in the middle of a migration is never retried because that migration may be partially applied.

set -uo pipefail

MIGRATION_COMMAND="${MIGRATION_COMMAND:-npm run migrate}"
ATTEMPTS="${MIGRATION_ATTEMPTS:-3}"
RETRY_DELAY="${MIGRATION_RETRY_DELAY:-5}"
CONTENTION_DELAY="${MIGRATION_CONTENTION_DELAY:-30}"
STALL_TIMEOUT="${MIGRATION_STALL_TIMEOUT:-120}"
VPN_CONNECT_SCRIPT="${VPN_CONNECT_SCRIPT:-}"
VPN_CONFIG_PATH="${VPN_CONFIG_PATH:-vpn.conf}"
VPN_LOG_PATH="${VPN_LOG_PATH:-${RUNNER_TEMP:-/tmp}/openvpn.log}"
PG_PORT="${PG_PORT:-5432}"
TARGET="${MIGRATION_TARGET:-${APP_NAME:-app} · ${DEPLOY_ENV:-unknown env}}"
OUTPUT_PATH="${RUNNER_TEMP:-/tmp}/migration-attempt.log"
HISTORY_PATH="${RUNNER_TEMP:-/tmp}/migration-output.log"
SUMMARY_PATH="${GITHUB_STEP_SUMMARY:-/dev/null}"
OUTPUTS_PATH="${GITHUB_OUTPUT:-/dev/null}"

stage=""
stalled=false
reason=""
hint=""
retryable=false
pg_ip=""
resets_before=0

fail() {
  stage=$1
  reason=$2
  hint=$3
  retryable=$4
  return 1
}

is_private_ipv4() {
  [[ "$1" =~ ^10\. || "$1" =~ ^192\.168\. || "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]
}

vpn_resets() {
  local current
  current=$(sudo cat "$VPN_LOG_PATH" 2>/dev/null | grep -c "Connection reset, restarting")
  echo $((resets_before + current))
}

check_secrets() {
  local missing=()
  local name

  for name in PG_HOST PG_USER PG_PASSWORD PG_DB; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done

  ((${#missing[@]} == 0)) || fail "Configuration" \
    "missing secrets: ${missing[*]}" \
    "Add them to the '${DEPLOY_ENV:-target}' environment in this repository's settings (Settings → Environments)." \
    false
}

check_database_path() {
  pg_ip=$(getent ahostsv4 "$PG_HOST" | awk 'NR == 1 {print $1}')
  [[ -n "$pg_ip" ]] || fail "DNS" \
    "PG_HOST does not resolve" \
    "Check the PG_HOST secret of the '${DEPLOY_ENV:-target}' environment." \
    true || return 1

  is_private_ipv4 "$pg_ip" || fail "Configuration" \
    "PG_HOST resolves to the public address ${pg_ip}, so the connection bypasses the VPN and is dropped by the database firewall" \
    "Point PG_HOST at the database's private endpoint (a 10.x address inside the VPC)." \
    false || return 1

  local route
  route=$(ip route get "$pg_ip" 2>/dev/null)
  [[ "$route" == *"dev tun0"* ]] || fail "VPN" \
    "traffic to ${pg_ip} does not go through the tunnel ($(head -1 <<<"$route"))" \
    "The VPN session is down or did not install its routes." \
    true || return 1

  timeout 10 bash -c "exec 3<>/dev/tcp/${pg_ip}/${PG_PORT}" 2>/dev/null || fail "Database connection" \
    "no TCP connection to ${pg_ip}:${PG_PORT} through the VPN" \
    "The database is down, or its security group does not allow the VPN server." \
    true || return 1

  if [[ "${PG_SSL:-}" == "true" ]]; then
    local handshake
    handshake=$(timeout 15 openssl s_client -starttls postgres -connect "${pg_ip}:${PG_PORT}" -brief </dev/null 2>&1) || fail "Database connection" \
      "TLS handshake with ${pg_ip}:${PG_PORT} failed: $(tail -1 <<<"$handshake")" \
      "The tunnel dropped packets mid-handshake; this is retried on a fresh VPN session." \
      true || return 1
  fi
}

# Reads the structured logs of the repository's migrator (umzug events through gazeti).
migration_events() {
  jq -Rr --arg kind "$1" '
    fromjson? // empty
    | select((.event | type) == "object" and .event.event == $kind)
    | .event.name
  ' "${2:-$OUTPUT_PATH}"
}

migration_error() {
  local error
  error=$(jq -Rr 'fromjson? // empty | select(.indexed.message? == "Migration failed") | .indexed.error' "$OUTPUT_PATH" | tail -1)
  [[ -n "$error" ]] || error=$(grep -vE '^\s*$|^>' "$OUTPUT_PATH" | tail -3 | tr '\n' ' ')
  echo "${error:-the migration command exited without an error message}"
}

classify_migration_failure() {
  local error
  local in_flight
  error=$(migration_error)
  in_flight=$(comm -23 <(migration_events migrating | sort -u) <(migration_events migrated | sort -u) | head -1)

  if [[ "$error" =~ ECONNRESET|ETIMEDOUT|ECONNREFUSED|EHOSTUNREACH|ENETUNREACH|EPIPE|Connection\ terminated|socket\ hang\ up ]]; then
    if [[ -n "$in_flight" ]]; then
      fail "Migration ${in_flight}" \
        "the database connection was lost while this migration was running (${error})" \
        "It may be partially applied: check the database before re-running. It is not retried automatically." \
        false
    else
      fail "Database connection" \
        "the connection was cut before any migration started (${error})" \
        "Nothing was applied; this is retried on a fresh VPN session." \
        true
    fi
  elif [[ "$error" =~ password\ authentication\ failed|no\ pg_hba.conf\ entry ]]; then
    fail "Database login" "$error" "Check PG_USER/PG_PASSWORD in the '${DEPLOY_ENV:-target}' environment." false
  elif [[ "$error" =~ database\ .*\ does\ not\ exist ]]; then
    fail "Database login" "$error" "Check PG_DB in the '${DEPLOY_ENV:-target}' environment." false
  else
    fail "Migration ${in_flight:-(before the first migration)}" \
      "$error" \
      "This is an error in the migration code or data, not the network; fix it and push again." \
      false
  fi
}

write_summary() {
  local outcome=$1
  local attempt=$2
  local applied
  local resets
  # shellcheck disable=SC2016 # literal backticks for markdown
  applied=$(migration_events migrated "$HISTORY_PATH" 2>/dev/null | sed 's/^/- `/; s/$/`/')
  resets=$(vpn_resets)

  {
    if [[ "$outcome" == success ]]; then
      echo "### ✅ Migrations · ${TARGET}"
      echo
      if [[ -n "$applied" ]]; then
        echo "Applied:"
        echo "$applied"
      else
        echo "No pending migrations."
      fi
      ((attempt > 1)) && echo && echo "Succeeded on attempt ${attempt}/${ATTEMPTS}."
    else
      echo "### ❌ Migrations · ${TARGET}"
      echo
      echo "| | |"
      echo "|---|---|"
      echo "| **Failed at** | ${stage} |"
      echo "| **Error** | ${reason//|/\\|} |"
      echo "| **What to do** | ${hint} |"
      ((attempt > 0)) && echo "| **Attempts** | ${attempt}/${ATTEMPTS} |"
      if ((resets > 0)); then
        echo "| **VPN** | session reset ${resets}× by the server: another job connected with the same shared VPN certificate and took over the session |"
      fi
      if [[ -n "$applied" ]]; then
        echo
        echo "Applied before the failure:"
        echo "$applied"
      fi
    fi
  } >>"$SUMMARY_PATH"

  {
    echo "stage=${stage}"
    echo "reason=${reason}"
    echo "applied=$(migration_events migrated "$HISTORY_PATH" 2>/dev/null | paste -sd, -)"
  } >>"$OUTPUTS_PATH"
}

# A connection cut mid-read leaves node waiting forever, so an attempt that has not started any
# migration within STALL_TIMEOUT is killed and retried. Once a migration runs it is never killed.
run_migration_command() {
  local pid
  local started=$SECONDS
  stalled=false

  # setsid gives the command its own process group so the watchdog can stop npm, node and tee together.
  # shellcheck disable=SC2016 # expanded by the child shell
  setsid bash -c '$0 2>&1 | tee "$1"; exit "${PIPESTATUS[0]}"' "$MIGRATION_COMMAND" "$OUTPUT_PATH" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS - started >= STALL_TIMEOUT)) && ! grep -q '"migrating"' "$OUTPUT_PATH"; then
      stalled=true
      kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      break
    fi
    sleep 1
  done

  wait "$pid"
}

reconnect_vpn() {
  [[ -n "$VPN_CONNECT_SCRIPT" ]] || return 0
  echo "Reconnecting the VPN before retrying"
  resets_before=$(vpn_resets)
  bash "$VPN_CONNECT_SCRIPT" "$VPN_CONFIG_PATH"
}

: >"$OUTPUT_PATH"
: >"$HISTORY_PATH"

if ! check_secrets; then
  echo "::error title=Migration failed: ${stage}::${reason}. ${hint}"
  write_summary failure 0
  exit 1
fi

# The action runs this first, alone, so missing secrets fail the job before any setup work.
[[ "${1:-}" == "--check-secrets" ]] && exit 0

for attempt in $(seq 1 "$ATTEMPTS"); do
  if ((attempt > 1)); then
    if (($(vpn_resets) > 0)); then
      # Our reconnect would kick the other job's session in turn, so step aside while it works.
      backoff=$((CONTENTION_DELAY * (attempt - 1)))
      echo "::notice title=VPN shared with another job::the server reset this session; disconnecting for ${backoff}s so the other job can finish"
      sudo pkill -x openvpn 2>/dev/null || true
      sleep "$backoff"
    else
      sleep "$RETRY_DELAY"
    fi
    reconnect_vpn || true
  fi

  if check_database_path; then
    echo "Database ${pg_ip}:${PG_PORT} is reachable through the VPN (attempt ${attempt}/${ATTEMPTS})"
    run_migration_command
    status=$?
    cat "$OUTPUT_PATH" >>"$HISTORY_PATH"
    if ((status == 0)); then
      write_summary success "$attempt"
      exit 0
    elif [[ "$stalled" == true ]]; then
      fail "Database connection" \
        "no answer from the database for ${STALL_TIMEOUT}s before any migration started" \
        "Nothing was applied; the attempt was stopped and is retried on a fresh VPN session." \
        true
    else
      classify_migration_failure
    fi
  fi

  if [[ "$retryable" != true || "$attempt" == "$ATTEMPTS" ]]; then
    break
  fi
  echo "::warning title=Migration attempt ${attempt}/${ATTEMPTS} failed (${stage})::${reason}"
done

if [[ "$retryable" == true ]] && (($(vpn_resets) > 0)); then
  hint="Another CI job was connected with the same VPN certificate, and the VPN server keeps one session per certificate. Re-run once it is done; enabling duplicate-cn on the VPN server (auctelia/Infrastructure) removes this limit."
fi

echo "::error title=Migration failed: ${stage}::${reason}. ${hint}"
write_summary failure "$attempt"
exit 1
