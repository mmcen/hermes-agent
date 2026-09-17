#!/bin/sh
# shellcheck shell=sh
# Entry-point dispatcher for runtimes that may or may not give the image
# ownership of PID 1.
#
# Normal Docker / Podman path: this script is PID 1, so we delegate to
# s6-overlay's /init exactly as before and keep the full supervision tree.
#
# Wrapped-runtime path (Fly Machines, `docker run --init`, Railway,
# CloudFoundry/diego, some Nomad/K8s setups): the platform's own init is
# already PID 1 and execs the image entrypoint as a child. s6-overlay
# aborts there with "can only run as pid 1", so we run the stage2 bootstrap
# ourselves, assemble a small s6 scan directory from
# /opt/hermes/docker/s6-fallback/service and run `s6-svscan` as a child to
# supervise the side services (cloudflared / dashboard / sshd). A crashed
# service is then restarted in place instead of silently disappearing, and
# `s6` (see /usr/local/bin/s6) can drive them by hand.
#
# The container's main program stays the user's CMD, run through
# main-wrapper.sh as before — the container still exits when that command
# exits (Architecture B).

set -e

if [ "$$" -eq 1 ]; then
    exec /init /opt/hermes/docker/main-wrapper.sh "$@"
fi

echo "[hermes] WARNING: container entrypoint is not PID 1; skipping s6-overlay /init and falling back to direct bootstrap + s6-supervised side services." >&2
# /init normally seeds PATH with s6's helpers; the non-PID-1 fallback skips it.
export PATH="/command:/package/admin/s6/command:${PATH}"
/opt/hermes/docker/stage2-hook.sh

DATA="${HERMES_HOME:-/opt/data}"
mkdir -p "$DATA/logs"
chown -R hermes:hermes "$DATA" 2>/dev/null || true

# --- assemble the supervised scan directory ---------------------------------
# Service definitions live in docker/s6-fallback/service; each one delegates to
# the matching s6-rc.d/run script, so behaviour (token guard, HERMES_DASHBOARD
# gate, authorized_keys seeding, privilege drops) matches the s6-overlay path.
SCANDIR=/run/hermes-s6/service
SRC=/opt/hermes/docker/s6-fallback/service

enable() {
    s="$1"
    [ -d "$SRC/$s" ] || { echo "[hermes] service definition missing: $s" >&2; return 0; }
    cp -R "$SRC/$s" "$SCANDIR/$s"
    chmod 0755 "$SCANDIR/$s" 2>/dev/null || true
    chmod 0755 "$SCANDIR/$s/run" 2>/dev/null || true
    [ -f "$SCANDIR/$s/finish" ] && chmod 0755 "$SCANDIR/$s/finish" 2>/dev/null || true
    return 0
}

rm -rf "$SCANDIR"
mkdir -p "$SCANDIR"

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    enable cloudflared
else
    echo "[hermes] TUNNEL_TOKEN unset — cloudflared not supervised" >&2
fi

case "${HERMES_DASHBOARD:-}" in
    1|true|TRUE|True|yes|YES|Yes)
        enable dashboard ;;
    *)
        echo "[hermes] HERMES_DASHBOARD off — dashboard not supervised" >&2 ;;
esac

case "${SSH_ENABLED:-}" in
    1|true|TRUE|True|yes|YES|Yes)
        export SSH_PORT="${SSH_PORT:-2222}"
        enable sshd ;;
    *)
        echo "[hermes] SSH_ENABLED unset/false — sshd not supervised" >&2 ;;
esac

if [ -n "$(ls -A "$SCANDIR" 2>/dev/null)" ]; then
    s6-svscan "$SCANDIR" &
    echo "[hermes] s6-svscan supervising:$(for d in "$SCANDIR"/*; do [ -d "$d" ] && printf ' %s' "$(basename "$d")"; done)" >&2
else
    echo "[hermes] no side services enabled — nothing to supervise" >&2
fi

exec /opt/hermes/docker/main-wrapper.sh "$@"
