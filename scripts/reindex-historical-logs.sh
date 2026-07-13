#!/usr/bin/env bash
# Collapse the rollover log indices into a single, de-duplicated historical
# index, then swap it in.
#
# WHY: logs-otel-v1 is an ISM rollover ALIAS with many backing indices. The
# deterministic _id (attributes.log_uid) only dedupes WITHIN one index, so every
# replay of the historical ingest landed fresh copies in the current write index
# while the originals stayed in older backing indices -> ~1.8M cross-index
# duplicates (see scripts/check-duplicate-logs.sh). Reindexing the whole alias
# into ONE fixed index makes identical _id docs overwrite each other, so the
# duplicates collapse. From then on this is a static, self-managed archive:
# replays overwrite by _id, no rollover, no duplication.
#
# WHAT IT DOES
#   1. Create DEST (2 primary shards, 0 replicas), detach ISM.
#   2. Reindex the SRC alias -> DEST (default op_type=index preserves _id and
#      overwrites, so duplicates collapse to one copy).
#   3. Verify DEST count against the source's distinct-fingerprint count.
#   4. Force-merge DEST (read-optimised archive).
#   5. SWAP (destructive, confirmed): delete the old numbered backing indices.
#   6. Refresh the OSD index-pattern field cache.
#
# PRECONDITION: ingestion must be PAUSED. You control the sender, so stop it
# before running — otherwise late writes to the rollover alias are lost in the
# swap. This script does not and cannot verify that for you.
#
# Usage:
#   DRY_RUN=1 scripts/reindex-historical-logs.sh   # preflight, read-only
#   scripts/reindex-historical-logs.sh             # do it (prompts before swap)
#   MERGE=0 scripts/reindex-historical-logs.sh     # skip force-merge
#   FORCE=1 scripts/reindex-historical-logs.sh     # recreate DEST if it exists
set -euo pipefail

source "$(dirname "$0")/_common.sh"

OS_URL="${OS_URL:-http://localhost:9200}"
SRC="${SRC:-logs-otel-v1}"                 # rollover alias -> reads all backing indices
DEST="${DEST:-logs-otel-v1-historical}"    # fixed index; matches logs-otel-v1* (OSD + template)
OLD_GLOB="${OLD_GLOB:-logs-otel-v1-0*}"    # numbered backing indices to remove in the swap
SHARDS="${SHARDS:-2}"
REPLICAS="${REPLICAS:-0}"                   # single node -> 0 keeps the index green
MERGE="${MERGE:-1}"
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

os()  { curl -s "${OS_AUTH[@]}" -H "Content-Type: application/json" "$@"; }
osc() { curl -s -o /dev/null -w '%{http_code}' "${OS_AUTH[@]}" -H "Content-Type: application/json" "$@"; }
die() { echo "ERROR: $1" >&2; exit 1; }

curl -s -m 5 "${OS_AUTH[@]}" "$OS_URL" >/dev/null || die "OpenSearch not reachable at $OS_URL"

echo "=== Reindex historical logs:  $SRC  ->  $DEST  (${SHARDS} shards, ${REPLICAS} replicas) ==="

# --- Preflight: source total, distinct fingerprints, and the swap target set ---
read -r SRC_TOTAL SRC_UNIQ < <(os "$OS_URL/$SRC/_search" -d '{
  "size":0,"track_total_hits":true,
  "aggs":{"u":{"cardinality":{"field":"attributes.log_uid","precision_threshold":40000}}}
}' | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['hits']['total']['value'],d['aggregations']['u']['value'])")
[ -n "${SRC_TOTAL:-}" ] || die "could not read source '$SRC' (does the alias exist?)"

echo "  source docs         : $(printf "%'d" "$SRC_TOTAL")"
echo "  distinct log_uid    : ~$(printf "%'d" "$SRC_UNIQ")  <- expected DEST size after dedup"
echo "  duplicates to shed  : ~$(printf "%'d" "$((SRC_TOTAL - SRC_UNIQ))")"
echo "  indices to drop     : $(os "$OS_URL/_cat/indices/$OLD_GLOB?h=index" | wc -l) matching '$OLD_GLOB'"

if [ "$DRY_RUN" = "1" ]; then
  echo; echo "DRY_RUN=1 — no changes made. Re-run without DRY_RUN to execute."
  exit 0
fi

# --- 1) Create DEST ---------------------------------------------------------
if [ "$(osc -I "$OS_URL/$DEST")" = "200" ]; then
  if [ "$FORCE" = "1" ]; then
    echo "--- DEST exists; FORCE=1 -> deleting and recreating ---"
    [ "$(osc -X DELETE "$OS_URL/$DEST")" = "200" ] || die "failed to delete existing $DEST"
  else
    die "$DEST already exists. Use FORCE=1 to recreate, or set DEST=<other>."
  fi
fi

echo "--- creating $DEST (mappings inherited from logs-otel-v1-index-template) ---"
# Only settings are overridden; the legacy template supplies the field mappings
# and dynamic_templates because DEST matches logs-otel-v1-*. rollover_alias from
# the template is nulled so ISM never tries to manage this index.
CODE=$(osc -X PUT "$OS_URL/$DEST" -d "{
  \"settings\": {
    \"index.number_of_shards\": $SHARDS,
    \"index.number_of_replicas\": $REPLICAS,
    \"index.refresh_interval\": \"-1\",
    \"index.opendistro.index_state_management.rollover_alias\": null
  }
}")
[ "$CODE" = "200" ] || die "create $DEST returned HTTP $CODE"
# Belt and braces: detach any ISM policy that auto-attached via an ism_template.
os -X POST "$OS_URL/_plugins/_ism/remove/$DEST" >/dev/null 2>&1 || true

# --- 2) Reindex (async, polled) --------------------------------------------
echo "--- reindexing (slices=auto, unthrottled)… ---"
TASK=$(os -X POST "$OS_URL/_reindex?wait_for_completion=false&slices=auto&requests_per_second=-1" -d "{
  \"source\": {\"index\": \"$SRC\", \"size\": 2000},
  \"dest\":   {\"index\": \"$DEST\"}
}" | python3 -c "import sys,json;print(json.load(sys.stdin).get('task',''))")
[ -n "$TASK" ] || die "reindex did not return a task id"
echo "  task: $TASK"

while :; do
  DONE=$(os "$OS_URL/_tasks/$TASK" | python3 -c "
import sys,json
d=json.load(sys.stdin)
s=d.get('task',{}).get('status',{})
created=s.get('created',0); total=s.get('total',0); conflicts=s.get('version_conflicts',0)
fail=d.get('error') or (d.get('response',{}) or {}).get('failures')
print('%s|%s|%s|%s|%s'%(d.get('completed',False),created,total,conflicts,bool(fail)))
")
  IFS='|' read -r completed created total conflicts hasfail <<< "$DONE"
  printf '\r  progress: %s / %s   conflicts=%s' "$created" "$total" "$conflicts"
  [ "$hasfail" = "True" ] && { echo; die "reindex reported failures — inspect GET _tasks/$TASK"; }
  [ "$completed" = "True" ] && { echo; break; }
  sleep 5
done

# --- 3) Verify --------------------------------------------------------------
os -X POST "$OS_URL/$DEST/_refresh" >/dev/null
DEST_TOTAL=$(os "$OS_URL/$DEST/_count" | python3 -c "import sys,json;print(json.load(sys.stdin)['count'])")
echo "  DEST docs           : $(printf "%'d" "$DEST_TOTAL")   (expected ~$(printf "%'d" "$SRC_UNIQ"))"
# cardinality is approximate (~<1% here); allow a small tolerance band.
LO=$((SRC_UNIQ - SRC_UNIQ/50)); HI=$((SRC_UNIQ + SRC_UNIQ/50))
if [ "$DEST_TOTAL" -lt "$LO" ] || [ "$DEST_TOTAL" -gt "$HI" ]; then
  die "DEST count $DEST_TOTAL outside expected band [$LO, $HI]. NOT swapping. Inspect $DEST before deleting anything."
fi
pass "DEST count within expected de-duplicated range"

# --- 4) Force-merge & restore refresh --------------------------------------
os -X PUT "$OS_URL/$DEST/_settings" -d '{"index.refresh_interval":"1s"}' >/dev/null
if [ "$MERGE" = "1" ]; then
  echo "--- force-merging $DEST to 1 segment/shard (read-optimised; may take a while)… ---"
  os -X POST "$OS_URL/$DEST/_forcemerge?max_num_segments=1" >/dev/null || echo "  (force-merge request returned non-200; safe to retry later)"
fi

# --- 5) Swap: delete the old numbered backing indices (destructive) ---------
echo
echo "About to DELETE the old rollover backing indices matching '$OLD_GLOB':"
os "$OS_URL/_cat/indices/$OLD_GLOB?v&s=index&h=index,docs.count,store.size"
echo
read -r -p "Type 'yes' to delete these and finish the swap: " ANS
if [ "$ANS" = "yes" ]; then
  CODE=$(osc -X DELETE "$OS_URL/$OLD_GLOB")
  [ "$CODE" = "200" ] && pass "old backing indices deleted" || fail "delete returned HTTP $CODE"
else
  echo "  skipped deletion — $DEST is populated but old indices remain (both match logs-otel-v1*)."
  echo "  Delete them later with:  curl -XDELETE \"\${OS_AUTH[@]}\" '$OS_URL/$OLD_GLOB'"
fi

# --- 6) Refresh OSD field caches -------------------------------------------
if [ -x "$(dirname "$0")/refresh-index-patterns.sh" ]; then
  echo "--- refreshing OSD index-pattern field caches ---"
  "$(dirname "$0")/refresh-index-patterns.sh" 'logs-otel-v1*' || true
fi

echo
echo "=== Done. '$DEST' is the de-duplicated archive. Point Data Prepper at it"
echo "    (data-prepper/pipelines.yml: index: \"$DEST\") so future replays overwrite by _id."
