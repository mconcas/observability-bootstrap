#!/bin/sh
# init-datasource.sh — Bootstrap OSD with workspace, Prometheus, and index patterns
#
# KEY CONCEPTS:
#
# 1. Workspaces: OSD 3.6 organises saved objects into workspaces.
#    The Observability use-case workspace unlocks the Traces/Metrics/Logs nav.
#
# 2. Data-connections vs data-sources:
#    - "data-source" (saved object)  → additional OpenSearch clusters
#    - "data-connection" (Direct Query) → non-OpenSearch backends (Prometheus, S3…)
#    Prometheus appears in the Discover data-source picker ONLY when registered
#    as a data-connection via the Direct Query API AND associated with a workspace.
#
# 3. Index patterns must be created INSIDE the workspace to be visible there.
#
# 4. OpenSearch needs plugins.query.datasources.encryption.masterkey to store
#    Direct Query credentials (set in docker-compose.yml on the opensearch service).

set -e

OSD_URL="http://opensearch-dashboards:5601"
USER="admin"
PASS="${OPENSEARCH_PASSWORD:-MyStr0ng!Pass#2024}"
AUTH="$USER:$PASS"
PROM_NAME="prometheus"

# Helper: HTTP request returning body on stdout with HTTP code on the last line
req() {
  curl -s -w "\n%{http_code}" -u "$AUTH" -H "osd-xsrf: true" -H "Content-Type: application/json" "$@"
}
http_code() { echo "$1" | tail -1; }
http_body() { echo "$1" | sed '$d'; }

# ─── Wait for OSD ────────────────────────────────────────────────────────────
echo "==> Waiting for OpenSearch Dashboards..."
until curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$OSD_URL/api/status" | grep -q '200'; do
  sleep 5
  echo "    still waiting..."
done
echo "==> OSD is up."

# ─── Step 1: Create or find Observability workspace ──────────────────────────
# The workspace scopes all our saved objects (index patterns, data-connections).
echo "==> Checking for existing Observability workspace..."
WS_LIST=$(req -X POST "$OSD_URL/api/workspaces/_list" -d '{}')
WS_ID=$(http_body "$WS_LIST" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
for ws in d.get('result',{}).get('workspaces',[]):
    if ws.get('name') == 'Observability':
        print(ws['id']); break
" 2>/dev/null || true)

if [ -n "$WS_ID" ]; then
  echo "    Found existing workspace: $WS_ID"
else
  echo "==> Creating Observability workspace..."
  WS_RESP=$(req -X POST "$OSD_URL/api/workspaces" -d '{
    "attributes": {
      "name": "Observability",
      "description": "Logs, traces, and metrics observability workspace",
      "features": ["use-case-observability"]
    }
  }')
  WS_ID=$(http_body "$WS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('id',''))" 2>/dev/null || true)
  if [ -n "$WS_ID" ]; then
    echo "    Created workspace: $WS_ID"
  else
    echo "    WARNING: could not create workspace. Continuing without workspace scoping."
    echo "    Response: $(http_body "$WS_RESP")"
  fi
fi

# ─── Step 2: Create Prometheus data-connection (Direct Query API) ────────────
# This makes Prometheus appear in the Discover data-source picker.
echo "==> Creating Prometheus data-connection..."
RESP=$(req -X POST "$OSD_URL/api/directquery/dataconnections" -d "{
  \"name\": \"$PROM_NAME\",
  \"allowedRoles\": [],
  \"connector\": \"prometheus\",
  \"properties\": {
    \"prometheus.uri\": \"http://prometheus:9090\",
    \"prometheus.auth.type\": \"basicauth\",
    \"prometheus.auth.username\": \"\",
    \"prometheus.auth.password\": \"\"
  }
}")
CODE=$(http_code "$RESP")
BODY=$(http_body "$RESP")
case "$CODE" in
  200) echo "    Created Prometheus data-connection." ;;
  *)
    if echo "$BODY" | grep -q "already exists"; then
      echo "    Prometheus data-connection already exists (OK)."
    else
      echo "    WARNING: HTTP $CODE — $BODY"
    fi
    ;;
esac

# ─── Step 3: Associate Prometheus data-connection with workspace ─────────────
# Without this, Prometheus won't appear when you're inside the workspace.
if [ -n "$WS_ID" ]; then
  echo "==> Associating Prometheus with workspace $WS_ID..."
  # Find the data-connection saved-object ID (simple curl, no helper)
  DC_RESP=$(curl -s -u "$AUTH" -H "osd-xsrf: true" \
    "$OSD_URL/api/saved_objects/_find?type=data-connection&per_page=100")
  DC_ID=$(echo "$DC_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for o in d.get('saved_objects',[]):
    if o.get('attributes',{}).get('connectionId') == '$PROM_NAME':
        print(o['id']); break
" 2>/dev/null || true)

  if [ -n "$DC_ID" ]; then
    ASSOC_RESP=$(req -X POST "$OSD_URL/api/workspaces/_associate" -d "{
      \"workspaceId\": \"$WS_ID\",
      \"savedObjects\": [{\"type\": \"data-connection\", \"id\": \"$DC_ID\"}]
    }")
    ASSOC_CODE=$(http_code "$ASSOC_RESP")
    echo "    Association HTTP $ASSOC_CODE"
  else
    echo "    WARNING: Could not find data-connection saved object for '$PROM_NAME'"
  fi
fi

# ─── Step 4: Create index patterns inside the workspace ─────────────────────
# Creating them via /w/<workspace_id>/api/... scopes them to the workspace.
# We capture the saved-object ID for each, needed later for correlations.
echo "==> Creating index patterns in workspace..."

create_index_pattern() {
  TITLE="$1"
  TIME_FIELD="$2"
  SIGNAL_TYPE="$3"       # "traces", "logs", or empty
  SCHEMA_MAPPINGS="$4"   # JSON string for field mapping, or empty
  if [ -n "$WS_ID" ]; then
    URL="$OSD_URL/w/$WS_ID/api/saved_objects/index-pattern"
    FIND_URL="$OSD_URL/w/$WS_ID/api/saved_objects/_find?type=index-pattern&search_fields=title&search=$TITLE&per_page=10"
  else
    URL="$OSD_URL/api/saved_objects/index-pattern"
    FIND_URL="$OSD_URL/api/saved_objects/_find?type=index-pattern&search_fields=title&search=$TITLE&per_page=10"
  fi
  PAYLOAD="{\"attributes\":{\"title\":\"$TITLE\""
  if [ -n "$TIME_FIELD" ]; then
    PAYLOAD="$PAYLOAD,\"timeFieldName\":\"$TIME_FIELD\""
  fi
  if [ -n "$SIGNAL_TYPE" ]; then
    PAYLOAD="$PAYLOAD,\"signalType\":\"$SIGNAL_TYPE\""
  fi
  if [ -n "$SCHEMA_MAPPINGS" ]; then
    PAYLOAD="$PAYLOAD,\"schemaMappings\":\"$SCHEMA_MAPPINGS\""
  fi
  PAYLOAD="$PAYLOAD}}"
  RESP=$(req -X POST "$URL" -d "$PAYLOAD")
  CODE=$(http_code "$RESP")
  BODY=$(http_body "$RESP")
  if [ "$CODE" = "200" ]; then
    # Extract ID from creation response
    IP_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    echo "    $TITLE -> created ($IP_ID)"
  elif echo "$BODY" | grep -q "Duplicate"; then
    # Already exists — look up the ID
    FIND_RESP=$(curl -s -u "$AUTH" -H "osd-xsrf: true" "$FIND_URL")
    IP_ID=$(echo "$FIND_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for o in d.get('saved_objects',[]):
    if o.get('attributes',{}).get('title') == '$TITLE':
        print(o['id']); break
" 2>/dev/null || true)
    echo "    $TITLE -> already exists ($IP_ID)"
    # Update signalType/schemaMappings if set (they may be missing from earlier creation)
    if [ -n "$IP_ID" ] && { [ -n "$SIGNAL_TYPE" ] || [ -n "$SCHEMA_MAPPINGS" ]; }; then
      UPD="{\"attributes\":{"
      SEP=""
      if [ -n "$SIGNAL_TYPE" ]; then
        UPD="$UPD\"signalType\":\"$SIGNAL_TYPE\""
        SEP=","
      fi
      if [ -n "$SCHEMA_MAPPINGS" ]; then
        UPD="$UPD${SEP}\"schemaMappings\":\"$SCHEMA_MAPPINGS\""
      fi
      UPD="$UPD}}"
      if [ -n "$WS_ID" ]; then
        UPD_URL="$OSD_URL/w/$WS_ID/api/saved_objects/index-pattern/$IP_ID"
      else
        UPD_URL="$OSD_URL/api/saved_objects/index-pattern/$IP_ID"
      fi
      UPD_RESP=$(req -X PUT "$UPD_URL" -d "$UPD")
      UPD_CODE=$(http_code "$UPD_RESP")
      echo "    $TITLE -> updated signalType=$SIGNAL_TYPE (HTTP $UPD_CODE)"
    fi
  else
    IP_ID=""
    echo "    $TITLE -> HTTP $CODE"
  fi
  # Return ID via output capture (caller uses $())
  echo "$IP_ID"
}

# signalType tells OSD Discover how to classify each index pattern.
# schemaMappings maps OTel field names to what OSD expects for cross-signal navigation.
LOGS_SCHEMA='{\"otelLogs\":{\"timestamp\":\"time\",\"traceId\":\"traceId\",\"spanId\":\"spanId\",\"serviceName\":\"resource.attributes.service.name\"}}'

# Create patterns, capture IDs (last line of output = ID)
LOGS_OUT=$(create_index_pattern "logs-otel-v1*" "time" "logs" "$LOGS_SCHEMA")
LOGS_IP_ID=$(echo "$LOGS_OUT" | tail -1)
echo "$LOGS_OUT" | sed '$d'  # print all but last line (the messages)

TRACES_OUT=$(create_index_pattern "otel-v1-apm-span*" "endTime" "traces" "")
TRACES_IP_ID=$(echo "$TRACES_OUT" | tail -1)
echo "$TRACES_OUT" | sed '$d'

SVCMAP_OUT=$(create_index_pattern "otel-v2-apm-service-map*" "timestamp" "" "")
SVCMAP_IP_ID=$(echo "$SVCMAP_OUT" | tail -1)
echo "$SVCMAP_OUT" | sed '$d'

echo "    Index pattern IDs: traces=$TRACES_IP_ID logs=$LOGS_IP_ID svcmap=$SVCMAP_IP_ID"

# ─── Step 5: Create correlations for APM ─────────────────────────────────────
# Correlations are saved objects that link traces ↔ logs and configure the
# APM Application Map (traces + service-map + Prometheus).
# This is what the "Trace Data Detected" dialog does when you click accept.

create_correlation() {
  CORR_TYPE="$1"
  CORR_TITLE="$2"
  ENTITIES_JSON="$3"
  REFS_JSON="$4"

  if [ -n "$WS_ID" ]; then
    URL="$OSD_URL/w/$WS_ID/api/saved_objects/correlations"
    FIND_URL="$OSD_URL/w/$WS_ID/api/saved_objects/_find?type=correlations&per_page=100"
  else
    URL="$OSD_URL/api/saved_objects/correlations"
    FIND_URL="$OSD_URL/api/saved_objects/_find?type=correlations&per_page=100"
  fi

  # Check if it already exists
  EXISTING=$(curl -s -u "$AUTH" -H "osd-xsrf: true" "$FIND_URL")
  FOUND=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
prefix = '$CORR_TYPE'.split('-')[0] + '-' + '$CORR_TYPE'.split('-')[1] if '-' in '$CORR_TYPE' else '$CORR_TYPE'
for o in d.get('saved_objects',[]):
    ct = o.get('attributes',{}).get('correlationType','')
    if ct.startswith(prefix):
        print(o['id']); break
" 2>/dev/null || true)

  if [ -n "$FOUND" ]; then
    echo "    $CORR_TITLE -> already exists ($FOUND)"
    return
  fi

  PAYLOAD="{
    \"attributes\": {
      \"correlationType\": \"$CORR_TYPE\",
      \"title\": \"$CORR_TITLE\",
      \"version\": \"1.0.0\",
      \"entities\": $ENTITIES_JSON
    },
    \"references\": $REFS_JSON"
  if [ -n "$WS_ID" ]; then
    PAYLOAD="$PAYLOAD, \"workspaces\": [\"$WS_ID\"]"
  fi
  PAYLOAD="$PAYLOAD}"

  RESP=$(req -X POST "$URL" -d "$PAYLOAD")
  CODE=$(http_code "$RESP")
  if [ "$CODE" = "200" ]; then
    echo "    $CORR_TITLE -> created"
  else
    echo "    $CORR_TITLE -> HTTP $CODE: $(http_body "$RESP")"
  fi
}

echo "==> Creating trace-to-logs correlation..."
# Links trace spans to their correlated log entries (by traceId)
if [ -n "$TRACES_IP_ID" ] && [ -n "$LOGS_IP_ID" ]; then
  create_correlation \
    "trace-to-logs-otel-v1-apm-span*" \
    "trace-to-logs_otel-v1-apm-span*" \
    '[{"tracesDataset":{"id":"references[0].id"}},{"logsDataset":{"id":"references[1].id"}}]' \
    "[{\"name\":\"entities[0].index\",\"type\":\"index-pattern\",\"id\":\"$TRACES_IP_ID\"},{\"name\":\"entities[1].index\",\"type\":\"index-pattern\",\"id\":\"$LOGS_IP_ID\"}]"
else
  echo "    SKIP: missing index pattern IDs (traces=$TRACES_IP_ID logs=$LOGS_IP_ID)"
fi

echo "==> Creating APM config correlation..."
# Links traces + service-map + Prometheus for the Application Map view
if [ -n "$TRACES_IP_ID" ] && [ -n "$SVCMAP_IP_ID" ] && [ -n "$DC_ID" ]; then
  create_correlation \
    "APM-Config-${WS_ID}" \
    "apm-config" \
    '[{"tracesDataset":{"id":"references[0].id"}},{"serviceMapDataset":{"id":"references[1].id"}},{"prometheusDataSource":{"id":"references[2].id"}}]' \
    "[{\"name\":\"entities[0].index\",\"type\":\"index-pattern\",\"id\":\"$TRACES_IP_ID\"},{\"name\":\"entities[1].index\",\"type\":\"index-pattern\",\"id\":\"$SVCMAP_IP_ID\"},{\"name\":\"entities[2].dataConnection\",\"type\":\"data-connection\",\"id\":\"$DC_ID\"}]"
else
  echo "    SKIP: missing IDs (traces=$TRACES_IP_ID svcmap=$SVCMAP_IP_ID dc=$DC_ID)"
fi

echo "==> Init complete."
echo "    Workspace: ${WS_ID:-none}"
echo "    Prometheus: $PROM_NAME (Direct Query)"
echo "    Correlations: trace-to-logs + APM-Config"
echo "    Navigate to: http://localhost:5601/w/$WS_ID/app/observability-traces"
