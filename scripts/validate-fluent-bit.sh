#!/usr/bin/env bash
# Validate that Fluent-Bit is running and forwarding logs
set -euo pipefail

source "$(dirname "$0")/_common.sh"

SERVICE="fluent-bit"
echo "=== Validating $SERVICE ==="

# 1. Container running
check_container_running "$SERVICE"

# 2. Forward input listening on port 24224
(echo >/dev/tcp/localhost/24224) 2>/dev/null \
  && pass "Forward input port 24224 open" \
  || fail "Forward input port 24224 not reachable"

# 3. Check container logs for output activity
LOG_LINES=$(docker logs "$SERVICE" 2>&1 | wc -l)
[ "$LOG_LINES" -gt 0 ] \
  && pass "Container has $LOG_LINES log lines" \
  || fail "No log output from container"

# 4. Verify other containers are configured to use fluentd logging driver
for svc in opensearch opensearch-dashboards prometheus otel-collector data-prepper; do
  DRIVER=$(docker inspect --format='{{.HostConfig.LogConfig.Type}}' "$svc" 2>/dev/null || echo "unknown")
  [ "$DRIVER" = "fluentd" ] \
    && pass "$svc using fluentd log driver" \
    || fail "$svc using $DRIVER (expected fluentd)"
done

summary
