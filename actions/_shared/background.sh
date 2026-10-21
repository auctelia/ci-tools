#!/usr/bin/env bash

# Lets independent setup work overlap across composite steps:
#   background.sh start <name> <command...>   runs the command detached, output in $RUNNER_TEMP/<name>.log
#   background.sh wait <name> [timeout]       blocks until it exits and fails with its output if it failed

set -euo pipefail

ACTION="${1:?usage: background.sh start|wait <name> ...}"
NAME="${2:?usage: background.sh start|wait <name> ...}"
shift 2

DIR="${RUNNER_TEMP:-/tmp}"
LOG_PATH="${DIR}/${NAME}.log"
EXIT_PATH="${DIR}/${NAME}.exit"

case "$ACTION" in
  start)
    rm -f "$EXIT_PATH"
    # shellcheck disable=SC2016 # expanded by the detached shell
    nohup bash -c 'log=$0 exit_file=$1; shift; "$@" >"$log" 2>&1; echo $? >"$exit_file.tmp"; mv "$exit_file.tmp" "$exit_file"' \
      "$LOG_PATH" "$EXIT_PATH" "$@" >/dev/null 2>&1 &
    ;;
  wait)
    TIMEOUT="${1:-300}"
    DEADLINE=$((SECONDS + TIMEOUT))
    until [[ -f "$EXIT_PATH" ]]; do
      if ((SECONDS >= DEADLINE)); then
        echo "::error title=${NAME}::did not finish within ${TIMEOUT}s"
        exit 1
      fi
      sleep 0.5
    done
    if [[ "$(<"$EXIT_PATH")" != 0 ]]; then
      echo "::group::${NAME} output"
      cat "$LOG_PATH"
      echo "::endgroup::"
      echo "::error title=${NAME} failed::$(grep -m1 -iE 'npm (ERR|error)|^E: ' "$LOG_PATH" || tail -1 "$LOG_PATH")"
      exit 1
    fi
    echo "${NAME} finished"
    ;;
  *)
    echo "unknown action: ${ACTION}" >&2
    exit 2
    ;;
esac
