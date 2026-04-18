#!/usr/bin/env bash
set -u

BACKOFF=1
MAX_BACKOFF=60
HEALTHY_THRESHOLD=60
SENTINEL=/home/user/.openclaw-ready
RESTARTS=0
CHILD_PID=

log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2
}

start_sshd() {
    mkdir -p /run/sshd
    ssh-keygen -A >/dev/null 2>&1
    /usr/sbin/sshd || log "sshd failed to start"
}

cleanup() {
    local signum=$1
    if [ -n "$CHILD_PID" ]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    exit $((128 + signum))
}
trap 'cleanup 15' TERM
trap 'cleanup 2'  INT
trap 'cleanup 1'  HUP
trap 'cleanup 3'  QUIT

start_sshd

log "Waiting for host init sentinel ($SENTINEL)..."
while [ ! -e "$SENTINEL" ]; do
    sleep 1 &
    wait $!
done
log "Sentinel seen, starting supervisor."

while true; do
    pgrep -x sshd >/dev/null 2>&1 || start_sshd
    START=$(date +%s)
    runuser -u user -- bash -lc 'exec openclaw gateway run' &
    CHILD_PID=$!
    wait "$CHILD_PID"
    EXIT_CODE=$?
    CHILD_PID=
    ELAPSED=$(( $(date +%s) - START ))
    RESTARTS=$((RESTARTS + 1))
    if [ "$EXIT_CODE" -eq 0 ] || [ "$ELAPSED" -ge "$HEALTHY_THRESHOLD" ]; then
        BACKOFF=1
    fi
    log "openclaw gateway exited ($EXIT_CODE) after ${ELAPSED}s (restart #$RESTARTS). Waiting ${BACKOFF}s..."
    sleep "$BACKOFF" &
    wait $!
    BACKOFF=$((BACKOFF * 2))
    [ "$BACKOFF" -gt "$MAX_BACKOFF" ] && BACKOFF=$MAX_BACKOFF
done
