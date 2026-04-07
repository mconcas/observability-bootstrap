#!/usr/bin/env bash
# Validate that the OTel Collector is running and accepting telemetry
set -euo pipefail

source "$(dirname "$0")/_common.sh"

SERVICE="otel-collector"
echo "=== Validating $SERVICE ==="

# 1. Container running
check_container_running "$SERVICE"

# 2. gRPC port open (4317)
(echo >/dev/tcp/localhost/4317) 2>/dev/null \
  && pass "gRPC port 4317 open" \
  || fail "gRPC port 4317 not reachable"

# 3. HTTP port open (4318)
(echo >/dev/tcp/localhost/4318) 2>/dev/null \
  && pass "HTTP port 4318 open" \
  || fail "HTTP port 4318 not reachable"

# 4. Internal metrics endpoint (8888)
METRICS=$(curl -s "http://localhost:8888/metrics" 2>/dev/null || echo "")
if echo "$METRICS" | grep -q "otelcol"; then
  pass "Internal metrics available on :8888"
else
  fail "Internal metrics not available on :8888"
fi

# 5. Check for span acceptance (via collector metrics endpoint)
ACCEPTED=$(curl -s "http://localhost:8888/metrics" 2>/dev/null |
  grep '^otelcol_receiver_accepted_spans_total' |
  grep -oP '\d+(\.\d+)?' | tail -1 || echo "0")

if [ -n "$ACCEPTED" ] && [ "$ACCEPTED" != "0" ]; then
  pass "Accepted spans: $ACCEPTED"
else
  fail "No spans accepted yet (may need traffic)"
fi

summary
