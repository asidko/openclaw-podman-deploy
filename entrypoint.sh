#!/bin/sh

BACKOFF=1
MAX_BACKOFF=60
HEALTHY_THRESHOLD=60
CHILD_PID=

start_sshd() {
    mkdir -p /run/sshd
    ssh-keygen -A >/dev/null 2>&1
    /usr/sbin/sshd
}

cleanup() {
    [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

start_sshd

while true; do
    START=$(date +%s)
    su - user -c "openclaw gateway run" &
    CHILD_PID=$!
    wait "$CHILD_PID"
    EXIT_CODE=$?
    CHILD_PID=
    ELAPSED=$(( $(date +%s) - START ))
    if [ "$ELAPSED" -ge "$HEALTHY_THRESHOLD" ]; then
        BACKOFF=1
    fi
    echo "[$(date)] openclaw gateway exited ($EXIT_CODE) after ${ELAPSED}s. Restarting in ${BACKOFF}s..." >&2
    sleep "$BACKOFF" &
    wait $!
    BACKOFF=$((BACKOFF * 2))
    [ "$BACKOFF" -gt "$MAX_BACKOFF" ] && BACKOFF=$MAX_BACKOFF
done
