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
# aborts there with "can only run as pid 1", so we run the stage2
# bootstrap directly, manually background the side services
# (cloudflared / sshd) that s6 would otherwise supervise, and then exec
# the main wrapper without /init.

set -e

if [ "$$" -eq 1 ]; then
    exec /init /opt/hermes/docker/main-wrapper.sh "$@"
fi

echo "[hermes] WARNING: container entrypoint is not PID 1; skipping s6-overlay /init and falling back to direct bootstrap + manual side-service startup." >&2
# /init normally seeds PATH with s6's helpers; the non-PID-1 fallback skips it.
export PATH="/command:/package/admin/s6/command:${PATH}"
/opt/hermes/docker/stage2-hook.sh

mkdir -p /opt/data/logs
chown -R hermes:hermes /opt/data 2>/dev/null || true

# --- cloudflared (manual, no s6 supervision available) ---
# The s6-rc.d/cloudflared/run script reads TUNNEL_TOKEN from the
# environment; in this fallback path the container env is intact, so we
# can hand it straight to `sh` (ignoring the with-contenv shebang).
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    (
        cd /opt/data || exit 1
        nohup sh /opt/hermes/docker/s6-rc.d/cloudflared/run \
            > /opt/data/logs/cloudflared.log 2>&1 &
    )
    echo "[hermes] cloudflared launched (TUNNEL_TOKEN set)" >&2
else
    echo "[hermes] TUNNEL_TOKEN unset, cloudflared skipped" >&2
fi

# --- sshd (manual, no s6 supervision available) ---
case "${SSH_ENABLED:-}" in
    1|true|TRUE|True|yes|YES|Yes)
        export SSH_PORT="${SSH_PORT:-2222}"
        (
            cd /opt/data || exit 1
            nohup sh /opt/hermes/docker/s6-rc.d/sshd/run \
                > /opt/data/logs/sshd.log 2>&1 &
        )
        echo "[hermes] sshd launched on ${SSH_PORT}" >&2
        ;;
    *)
        echo "[hermes] SSH_ENABLED unset/false, sshd skipped" >&2
        ;;
esac

exec /opt/hermes/docker/main-wrapper.sh "$@"
