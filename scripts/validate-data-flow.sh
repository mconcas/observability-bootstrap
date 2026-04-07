#!/usr/bin/env bash
# Validate end-to-end data flow: logs, traces, metrics reaching their stores
set -euo pipefail

source "$(dirname "$0")/_common.sh"

echo "=== Validating Data Flow ==="

# 1. Logs indexed in OpenSearch
LOG_COUNT=$(curl -sk -u "admin:${OPENSEARCH_PASSWORD}" \
  "https://localhost:9200/logs-otel-v1*/_count" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$LOG_COUNT" -gt 0 ] \
  && pass "Logs indexed: $LOG_COUNT documents" \
  || fail "No log documents in logs-otel-v1*"

# 2. Traces indexed in OpenSearch
TRACE_COUNT=$(curl -sk -u "admin:${OPENSEARCH_PASSWORD}" \
  "https://localhost:9200/otel-v1-apm-span*/_count" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$TRACE_COUNT" -gt 0 ] \
  && pass "Traces indexed: $TRACE_COUNT span documents" \
  || fail "No span documents in otel-v1-apm-span*"

# 3. Service-map documents in OpenSearch
SVCMAP_COUNT=$(curl -sk -u "admin:${OPENSEARCH_PASSWORD}" \
  "https://localhost:9200/otel-v2-apm-service-map*/_count" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
[ "$SVCMAP_COUNT" -gt 0 ] \
  && pass "Service-map docs: $SVCMAP_COUNT" \
  || fail "No documents in otel-v2-apm-service-map*"

# 4. Span metrics in Prometheus
SPAN_SERIES=$(curl -s "http://localhost:9090/api/v1/query?query=traces_span_metrics_calls_total" 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data.get('data',{}).get('result',[])))
" 2>/dev/null || echo "0")
[ "$SPAN_SERIES" -gt 0 ] \
  && pass "Span metric series in Prometheus: $SPAN_SERIES" \
  || fail "No span metrics in Prometheus"

# 5. OTel Collector metrics scraped by Prometheus
OTEL_UP=$(curl -s 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22otel-collector%22%7D' 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data',{}).get('result',[])
print(results[0]['value'][1] if results else '0')
" 2>/dev/null || echo "0")
[ "$OTEL_UP" = "1" ] \
  && pass "Prometheus scraping otel-collector" \
  || fail "otel-collector scrape target down"

# 6. Data Prepper metrics scraped by Prometheus
DP_UP=$(curl -s 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22data-prepper%22%7D' 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('data',{}).get('result',[])
print(results[0]['value'][1] if results else '0')
" 2>/dev/null || echo "0")
[ "$DP_UP" = "1" ] \
  && pass "Prometheus scraping data-prepper" \
  || fail "data-prepper scrape target down"

summary
