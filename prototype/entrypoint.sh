#!/bin/sh
# entrypoint.sh — SIGTERM-aware wrapper for opencode serve
#
# opencode's serve command has no SIGTERM handler (server.stop() is dead code
# behind `await new Promise(() => {})`). This wrapper catches SIGTERM from CF/Diego
# and forwards it to the opencode process, giving it up to graceful_shutdown_interval
# (default 10s in Diego) to finish in-flight requests.

set -e

# Default port — CF injects $PORT, but opencode ignores env vars for port
PORT="${PORT:-8080}"

# Warn if running unsecured (informational only — CF handles mTLS at the router)
if [ -z "$OPENCODE_SERVER_PASSWORD" ]; then
  echo "WARNING: OPENCODE_SERVER_PASSWORD not set — opencode API is unsecured"
fi

echo "Starting opencode serve on 0.0.0.0:${PORT}"

# Start opencode in the background
opencode serve --hostname 0.0.0.0 --port "$PORT" &
PID=$!

# Forward SIGTERM to opencode and wait for it to exit
trap 'echo "SIGTERM received, forwarding to opencode (PID=$PID)"; kill -TERM $PID' TERM INT

# Wait for opencode to exit
wait $PID
EXIT_CODE=$?

echo "opencode exited with code $EXIT_CODE"
exit $EXIT_CODE
