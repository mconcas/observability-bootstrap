#!/usr/bin/env bash
# validate.sh — end-to-end pipeline validation for DPL observability stack.
# Runs the diamond workflow, then checks InfoLogger (MariaDB) and traces (OpenSearch).
# Requires: docker, socat, alienv with O2/latest-otel-tracing-o2

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=1; }
info() { echo -e "${YELLOW}→${NC} $1"; }

FAILED=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENSEARCH_PASSWORD="MyStr0ng!Pass#2024"
ALIENV_PKG="O2/latest-otel-tracing-o2"
SOCKET=/tmp/infoLoggerD.socket
CLIENT_CFG="$HOME/.infoLoggerClient.cfg"
SOCAT_STARTED=0

# ── 1. Containers ─────────────────────────────────────────────────────────────
info "Checking containers..."
for svc in fluent-bit opensearch mariadb infologger-server otel-collector data-prepper; do
  if docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --status running "$svc" 2>/dev/null | grep -q "$svc"; then
    pass "  $svc running"
  else
    fail "  $svc not running"
  fi
done

# ── 2. socat bridge macOS → container ────────────────────────────────────────
info "Starting socat bridge (${SOCKET} → localhost:6007)..."
pkill -f "socat.*infoLoggerD" 2>/dev/null; sleep 0.5
rm -f "$SOCKET"
socat UNIX-LISTEN:"$SOCKET",reuseaddr,fork TCP:localhost:6007 &
SOCAT_STARTED=$!
sleep 1
if pgrep -f "socat.*infoLoggerD" >/dev/null 2>&1; then
  pass "  socat bridge running (pid $SOCAT_STARTED)"
else
  fail "  socat bridge failed to start — check port 6007 and container"
fi

# Verify full chain: macOS socket → container infoLoggerD → server → MariaDB
info "Testing InfoLogger chain (socket → infoLoggerD → MariaDB)..."
MSGS_CHAIN_BEFORE=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T mariadb \
  mariadb -h 127.0.0.1 -u infoLoggerAdmin -pilgadmin INFOLOGGER \
  -se "SELECT COUNT(*) FROM messages;" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T infologger-server bash -c \
  'pkill -f o2-infologger-daemon 2>/dev/null; sleep 0.5
   O2_INFOLOGGER_CONFIG=file:/etc/o2.d/infologger/infoLogger.cfg \
   /opt/o2-InfoLogger/bin/o2-infologger-daemon &
   sleep 1
   O2_INFOLOGGER_CONFIG=file:/etc/o2.d/infologger/infoLogger.cfg \
   /opt/o2-InfoLogger/bin/o2-infologger-log "validate.sh chain test"
   sleep 2' >/dev/null 2>&1
sleep 2
MSGS_CHAIN_AFTER=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T mariadb \
  mariadb -h 127.0.0.1 -u infoLoggerAdmin -pilgadmin INFOLOGGER \
  -se "SELECT COUNT(*) FROM messages;" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
if [[ $(( ${MSGS_CHAIN_AFTER:-0} - ${MSGS_CHAIN_BEFORE:-0} )) -gt 0 ]]; then
  pass "  InfoLogger chain working (server→MariaDB confirmed)"
else
  fail "  InfoLogger chain broken (server→MariaDB not working)"
fi

# ── 3. InfoLogger client config ───────────────────────────────────────────────
cat > "$CLIENT_CFG" <<EOF
[client]
txSocketPath=${SOCKET}
EOF
pass "  wrote $CLIENT_CFG"

# ── 4. Run diamond workflow for 10 s ─────────────────────────────────────────
info "Running diamond workflow (10 s)..."
RUN_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_TS_UNIX=$(date +%s)

# Snapshot span + message counts before the run
SPANS_BEFORE=$(curl -sk -u "admin:${OPENSEARCH_PASSWORD}" \
  "https://localhost:9200/otel-v1-apm-span-*/_count" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
MSGS_BEFORE=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T mariadb \
  mariadb -h 127.0.0.1 -u infoLoggerAdmin -pilgadmin INFOLOGGER \
  -se "SELECT COUNT(*) FROM messages;" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")

export O2_INFOLOGGER_MODE=infoLoggerD
export O2_INFOLOGGER_CONFIG="file:${CLIENT_CFG}"
export O2_DPL_DEPLOYMENT_MODE=OnlineECS   # required to load InfoLogger FairLogger sink

# Quick smoke-test: does this binary emit spans at all?
# DYLD_LIBRARY_PATH must be set inside alienv's env (where $O2_ROOT is defined)
# so that uv_dlopen("libO2FrameworkDataTakingSupport.dylib") can find the plugin.
info "  Smoke-testing tracing with stdout:// backend..."
STDOUT_SPANS=$(timeout 15 alienv setenv "$ALIENV_PKG" -c \
  'export DYLD_LIBRARY_PATH="$O2_ROOT/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
   o2-testworkflows-diamond-workflow --run --shm-segment-size 20000000 \
     --tracing-backend stdout:// --infologger-severity Info' \
  2>&1 | grep -c "dpl/process\|traceId" || true)
if [[ "${STDOUT_SPANS:-0}" -gt 0 ]]; then
  pass "  Tracing compiled in (${STDOUT_SPANS} span lines on stdout)"
else
  fail "  No spans on stdout — O2_WITH_DPL_TRACING likely not compiled in this binary"
fi

timeout 30 alienv setenv "$ALIENV_PKG" -c \
  'export DYLD_LIBRARY_PATH="$O2_ROOT/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
   o2-testworkflows-diamond-workflow --run --shm-segment-size 20000000 \
     --tracing-backend otlp-grpc://localhost:4317 --infologger-severity Info' \
  || true   # timeout exits 124 — that's expected

pass "  workflow finished"

# ── 5. Propagation wait ───────────────────────────────────────────────────────
info "Waiting 20 s for OTel batch flush + Data Prepper indexing..."
sleep 20

# ── 6. InfoLogger → MariaDB ───────────────────────────────────────────────────
info "Checking InfoLogger messages in MariaDB..."
MSGS_AFTER=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T mariadb \
  mariadb -h 127.0.0.1 -u infoLoggerAdmin -pilgadmin INFOLOGGER \
  -se "SELECT COUNT(*) FROM messages;" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
MSG_DELTA=$(( ${MSGS_AFTER:-0} - ${MSGS_BEFORE:-0} ))

if [[ "$MSG_DELTA" -gt 0 ]]; then
  pass "  InfoLogger: +${MSG_DELTA} new messages in MariaDB"
else
  fail "  InfoLogger: no new messages in MariaDB (before=${MSGS_BEFORE}, after=${MSGS_AFTER})"
fi

# ── 7. Traces → OpenSearch ────────────────────────────────────────────────────
info "Checking traces in OpenSearch..."
SPANS_AFTER=$(curl -sk -u "admin:${OPENSEARCH_PASSWORD}" \
  "https://localhost:9200/otel-v1-apm-span-*/_count" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
SPAN_DELTA=$(( ${SPANS_AFTER:-0} - ${SPANS_BEFORE:-0} ))
SPAN_COUNT=$SPAN_DELTA

if [[ "$SPAN_DELTA" -gt 0 ]]; then
  pass "  Traces: +${SPAN_DELTA} new spans in OpenSearch"
else
  fail "  Traces: no new spans in OpenSearch (before=${SPANS_BEFORE}, after=${SPANS_AFTER})"
fi

# ── 8. Service map → OpenSearch ───────────────────────────────────────────────
info "Checking service map in OpenSearch..."
SVCMAP_COUNT=$(curl -sk -u "admin:${OPENSEARCH_PASSWORD}" \
  "https://localhost:9200/otel-v2-apm-service-map/_count" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" \
  2>/dev/null || echo "0")

if [[ "${SVCMAP_COUNT:-0}" -gt 0 ]]; then
  pass "  Service map: ${SVCMAP_COUNT} edges in OpenSearch"
else
  fail "  Service map: no entries in OpenSearch"
fi

# ── Cleanup socat if we started it ───────────────────────────────────────────
if [[ "$SOCAT_STARTED" -ne 0 ]]; then
  kill "$SOCAT_STARTED" 2>/dev/null || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo -e "${GREEN}All checks passed.${NC}"
else
  echo -e "${RED}One or more checks failed.${NC}"
  exit 1
fi
