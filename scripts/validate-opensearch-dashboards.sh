#!/usr/bin/env bash
# Validate that OpenSearch Dashboards is running and configured
set -euo pipefail

source "$(dirname "$0")/_common.sh"

SERVICE="opensearch-dashboards"
echo "=== Validating $SERVICE ==="

# 1. Container running
check_container_running "$SERVICE"

# 2. OSD API responding
HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' \
  "http://localhost:5601/api/status" 2>/dev/null || echo "000")
[ "$HTTP_CODE" = "200" ] \
  && pass "API responding (HTTP $HTTP_CODE)" \
  || fail "API returned HTTP $HTTP_CODE"

# 3. Observability workspace exists
WS=$(curl -s -H "osd-xsrf: true" -H "Content-Type: application/json" \
  -X POST "http://localhost:5601/api/workspaces/_list" -d '{}' 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for ws in d.get('result',{}).get('workspaces',[]):
    if ws.get('name') == 'Observability':
        print(ws['id']); break
else:
    print('')
" 2>/dev/null || echo "")

[ -n "$WS" ] \
  && pass "Observability workspace: $WS" \
  || fail "Observability workspace not found"

# 4. Prometheus data-connection registered
DC=$(curl -s -H "osd-xsrf: true" \
  "http://localhost:5601/api/saved_objects/_find?type=data-connection&per_page=100" 2>/dev/null | \
  grep -c "prometheus" || echo "0")
[ "$DC" -ge 1 ] \
  && pass "Prometheus data-connection found" \
  || fail "Prometheus data-connection missing"

# 5. Index patterns exist
for pattern in "otel-v1-apm-span*" "logs-otel-v1*" "otel-v2-apm-service-map*"; do
  FOUND=$(curl -s -H "osd-xsrf: true" \
    "http://localhost:5601/api/saved_objects/_find?type=index-pattern&search_fields=title&search=${pattern}&per_page=10" 2>/dev/null | \
    python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('total',0))
" 2>/dev/null || echo "0")
  [ "$FOUND" -ge 1 ] \
    && pass "Index pattern $pattern exists" \
    || fail "Index pattern $pattern missing"
done

summary
