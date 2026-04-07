#!/usr/bin/env bash
# Validate that Data Prepper is running and pipelines are active
set -euo pipefail

source "$(dirname "$0")/_common.sh"

SERVICE="data-prepper"
echo "=== Validating $SERVICE ==="

# 1. Container running
check_container_running "$SERVICE"

# 2. Metrics endpoint accessible (check via Prometheus scrape target status)
DP_HEALTH=$(curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('data',{}).get('activeTargets',[]):
    if t['labels'].get('job') == 'data-prepper':
        print(t['health']); break
else:
    print('unknown')
" 2>/dev/null || echo "unknown")
if [ "$DP_HEALTH" = "up" ]; then
  pass "Metrics endpoint healthy (Prometheus target up)"
else
  fail "Metrics endpoint: Prometheus target is $DP_HEALTH"
fi

# 3. OTLP source listening on port 21890 (check via logs)
if docker logs "$SERVICE" 2>&1 | grep -q "Started otlp source on port 21890"; then
  pass "OTLP source started on port 21890"
else
  fail "OTLP source not started (check logs)"
fi

# 4. No pipeline construction errors in current run (last 200 lines after final startup)
LAST_START_LINE=$(docker logs "$SERVICE" 2>&1 | grep -n "Started otlp source on port 21890" | tail -1 | cut -d: -f1)
if [ -n "$LAST_START_LINE" ]; then
  ERRORS=$(docker logs "$SERVICE" 2>&1 | tail -n +"$LAST_START_LINE" | grep -c "Construction of pipeline components failed" || true)
else
  ERRORS=$(docker logs "$SERVICE" 2>&1 | grep -c "Construction of pipeline components failed" || true)
fi
if [ "$ERRORS" -eq 0 ]; then
  pass "No pipeline construction errors in current run"
else
  fail "$ERRORS pipeline construction error(s) found"
fi

# 5. OpenSearch sinks initialized
SINKS=$(docker logs "$SERVICE" 2>&1 | grep -c "Initialized OpenSearch sink" || true)
if [ "$SINKS" -ge 3 ]; then
  pass "All OpenSearch sinks initialized ($SINKS)"
else
  fail "Only $SINKS/3 OpenSearch sinks initialized"
fi

summary
