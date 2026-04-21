#!/usr/bin/env bash
# Validate that OpenSearch is running and healthy
set -euo pipefail

source "$(dirname "$0")/_common.sh"

SERVICE="opensearch"
echo "=== Validating $SERVICE ==="

# 1. Container running
check_container_running "$SERVICE"

# 2. Cluster health
STATUS=$(curl -s \
  "http://localhost:9200/_cluster/health" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unreachable")

case "$STATUS" in
  green|yellow) pass "Cluster health: $STATUS" ;;
  *)            fail "Cluster health: $STATUS" ;;
esac

# 3. Node responding
NODE_COUNT=$(curl -s \
  "http://localhost:9200/_cluster/health" | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('number_of_nodes',0))" 2>/dev/null || echo "0")

[ "$NODE_COUNT" -ge 1 ] && pass "Nodes: $NODE_COUNT" || fail "Nodes: $NODE_COUNT (expected >= 1)"

summary
