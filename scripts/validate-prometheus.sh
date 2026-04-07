#!/usr/bin/env bash
# Validate that Prometheus is running and scrape targets are up
set -euo pipefail

source "$(dirname "$0")/_common.sh"

SERVICE="prometheus"
echo "=== Validating $SERVICE ==="

# 1. Container running
check_container_running "$SERVICE"

# 2. Health endpoint
curl -sf "http://localhost:9090/-/healthy" >/dev/null 2>&1 \
  && pass "Health endpoint responding" \
  || fail "Health endpoint not responding"

# 3. Scrape targets
curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('data',{}).get('activeTargets',[]):
    job = t['labels'].get('job','?')
    health = t['health']
    status = 'PASS' if health == 'up' else 'FAIL'
    print(f'  {status}: scrape target {job} -> {health}')
" 2>/dev/null || fail "Could not query targets API"

# 4. OTLP receiver enabled (check config flags)
curl -sf "http://localhost:9090/api/v1/status/flags" 2>/dev/null | python3 -c "
import sys, json
flags = json.load(sys.stdin).get('data',{})
otlp = flags.get('web.enable-otlp-receiver','false')
rw = flags.get('web.enable-remote-write-receiver','false')
print(f'  {\"PASS\" if otlp == \"true\" else \"FAIL\"}: OTLP receiver enabled={otlp}')
print(f'  {\"PASS\" if rw == \"true\" else \"FAIL\"}: Remote write receiver enabled={rw}')
" 2>/dev/null || fail "Could not query flags API"

summary
