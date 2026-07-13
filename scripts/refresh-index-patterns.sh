#!/usr/bin/env bash
# Refresh the cached field list of OSD index patterns via the Dashboards API.
#
# WHY: index patterns cache their field list on the saved object at creation
# time (init-datasource.py runs the refresh ONCE, at bootstrap). Fields that
# appear in the mapping later — e.g. resource.attributes.service.name and
# attributes.log_uid once historical logs are ingested — are absent from that
# cache, so Discover renders them with a "?" icon and refuses to aggregate on
# them. This re-reads the live mapping and rewrites the cache, exactly like the
# "Refresh field list" (↻) button in Stack Management → Index Patterns.
#
# Safe to re-run at any time. Run it after a one-off historical ingest or
# whenever new attribute keys start flowing.
#
# Usage:
#   scripts/refresh-index-patterns.sh                       # refresh the defaults
#   scripts/refresh-index-patterns.sh 'logs-otel-v1*'       # refresh specific patterns
set -euo pipefail

source "$(dirname "$0")/_common.sh"

OSD_URL="${OSD_URL:-http://localhost:5601}"

# Patterns to refresh (defaults match init-datasource.py). Override via args.
if [ "$#" -gt 0 ]; then
  PATTERNS=("$@")
else
  PATTERNS=("logs-otel-v1*" "otel-v1-apm-span*" "otel-v2-apm-service-map*")
fi

# curl wrapper: OSD requires HTTP Basic (security plugin) + the osd-xsrf header
# on every request, including GETs.
osd() {
  curl -s "${OS_AUTH[@]}" -H "osd-xsrf: true" -H "Content-Type: application/json" "$@"
}

echo "=== Refreshing OSD index-pattern field caches ==="

# Locate the Observability workspace. Index patterns created by the init live
# inside it, so every API call must be scoped to /w/<ws_id> to see them.
WS=$(osd -X POST "$OSD_URL/api/workspaces/_list" -d '{}' 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for ws in d.get('result', {}).get('workspaces', []):
    if ws.get('name') == 'Observability':
        print(ws['id']); break
" 2>/dev/null || echo "")

if [ -n "$WS" ]; then
  BASE="$OSD_URL/w/$WS"
  echo "  Workspace: Observability ($WS)"
else
  # Fall back to the global scope so the script still works on a bare deploy
  # that never created the workspace.
  BASE="$OSD_URL"
  echo "  Workspace: none found — using global scope"
fi

# Meta fields requested alongside the mapping, matching init-datasource.py so
# the cached list is identical to a fresh bootstrap.
META="meta_fields=_source&meta_fields=_id&meta_fields=_index&meta_fields=_score"

for pattern in "${PATTERNS[@]}"; do
  # Resolve the saved-object ID for this pattern title.
  IP_ID=$(osd "$BASE/api/saved_objects/_find?type=index-pattern&search_fields=title&search=${pattern}&per_page=100" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
want = sys.argv[1]
for o in d.get('saved_objects', []):
    if o.get('attributes', {}).get('title') == want:
        print(o['id']); break
" "$pattern" 2>/dev/null || echo "")

  if [ -z "$IP_ID" ]; then
    fail "$pattern — index pattern not found"
    continue
  fi

  # Read the live field list from the mapping (the "refresh" fetch).
  FIELDS=$(osd "$BASE/api/index_patterns/_fields_for_wildcard?pattern=${pattern}&${META}" 2>/dev/null || echo "")
  COUNT=$(printf '%s' "$FIELDS" | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin).get('fields', [])))
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")

  if [ "$COUNT" -le 0 ]; then
    fail "$pattern ($IP_ID) — no fields returned (index empty or missing?)"
    continue
  fi

  # Write the refreshed list back onto the saved object.
  BODY=$(printf '%s' "$FIELDS" | python3 -c "
import sys, json
fields = json.load(sys.stdin)['fields']
print(json.dumps({'attributes': {'fields': json.dumps(fields)}}))
")
  HTTP=$(osd -o /dev/null -w '%{http_code}' -X PUT \
    "$BASE/api/saved_objects/index-pattern/$IP_ID" -d "$BODY" 2>/dev/null || echo "000")

  if [ "$HTTP" = "200" ]; then
    pass "$pattern ($IP_ID) — cached $COUNT fields"
  else
    fail "$pattern ($IP_ID) — PUT returned HTTP $HTTP"
  fi
done

summary
