#!/bin/sh

BACKOFF=1
MAX_BACKOFF=60

while true; do
    su - user -c "export PATH=/home/user/.npm-global/bin:\$PATH; openclaw gateway run"
    EXIT_CODE=$?
    echo "[$(date)] openclaw gateway exited ($EXIT_CODE). Restarting in ${BACKOFF}s..." >&2
    sleep "$BACKOFF"
    BACKOFF=$((BACKOFF * 2))
    [ "$BACKOFF" -gt "$MAX_BACKOFF" ] && BACKOFF=$MAX_BACKOFF
done
