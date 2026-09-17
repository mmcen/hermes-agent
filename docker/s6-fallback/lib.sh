#!/bin/sh
# shellcheck shell=sh
# Shared helpers for the non-PID-1 fallback service definitions.
# Sourced (not executed) by docker/s6-fallback/service/*/run.

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|True|yes|YES|Yes|on|ON) return 0 ;;
    esac
    return 1
}

# State directory used by the supervised processes. HERMES_HOME wins; the
# image default is /opt/data (see docker/stage2-hook.sh).
state_dir() {
    printf '%s' "${HERMES_HOME:-/opt/data}"
}

log_dir() {
    printf '%s/logs' "$(state_dir)"
}
