#!/usr/bin/env bash
# Detect duplicate log documents in the OpenSearch log indices.
#
# WHY: logs are written with a deterministic _id (attributes.log_uid, a content
# fingerprint computed in otel-collector/config.yml) so that replaying the
# ingestion pipeline OVERWRITES a record instead of duplicating it. But _id
# uniqueness in OpenSearch is per-INDEX, not per-alias. The write target
# `logs-otel-v1` is an ISM rollover alias with many backing indices
# (logs-otel-v1-000001, -000002, ...). When the pipeline is replayed, the new
# copies land in whatever index the alias currently rolls to, while the original
# copies sit in an older backing index. Same _id, different index => genuine
# duplicate across the alias, which the log_uid dedup cannot prevent.
#
# This script counts by the content fingerprint (log_uid), NOT by walking the
# raw telemetry: a duplicated fingerprint that appears in more than one backing
# index is a duplicated log line.
#
# Usage:
#   scripts/check-duplicate-logs.sh                 # default pattern, top 20
#   scripts/check-duplicate-logs.sh 'logs-otel-v1*' # explicit pattern
#   TOP=50 scripts/check-duplicate-logs.sh          # show more offenders
#
# Exit status: 0 if no duplicates found, 1 if duplicates found (or on error).
set -euo pipefail

source "$(dirname "$0")/_common.sh"

OS_URL="${OS_URL:-http://localhost:9200}"
PATTERN="${1:-logs-otel-v1*}"
TOP="${TOP:-20}"

os() { curl -s "${OS_AUTH[@]}" -H "Content-Type: application/json" "$@"; }

echo "=== Duplicate-log check on '${PATTERN}' ==="

# 1) Per-index doc counts. A fingerprint duplicated across two of these indices
#    is a cross-index duplicate. Empty indices (208b) are rolled-over, inactive.
echo
echo "--- backing indices (docs per index) ---"
os "$OS_URL/_cat/indices/${PATTERN}?s=index&h=index,docs.count,store.size,health" || true

# 2) Global tally: total docs vs. distinct fingerprints. The gap is the number
#    of duplicate copies. cardinality is approximate (HyperLogLog++) but with a
#    max precision_threshold the error is well under 1% here, enough to size the
#    problem. Also count docs with no log_uid (would predate the fingerprint
#    mechanism and could not be deduped at all).
echo
echo "--- global tally ---"
os "$OS_URL/${PATTERN}/_search" -d '{
  "size": 0,
  "track_total_hits": true,
  "aggs": {
    "unique_uid":  {"cardinality": {"field": "attributes.log_uid", "precision_threshold": 40000}},
    "missing_uid": {"missing": {"field": "attributes.log_uid"}}
  }
}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'error' in d:
    print('  ERROR:', json.dumps(d['error'])[:300]); sys.exit(2)
total   = d['hits']['total']['value']
uniq    = d['aggregations']['unique_uid']['value']
missing = d['aggregations']['missing_uid']['doc_count']
dup     = total - uniq
pct     = (dup / total * 100) if total else 0
print(f'  total docs        : {total:,}')
print(f'  distinct log_uid  : {uniq:,}  (approx)')
print(f'  duplicate copies  : {dup:,}  (~{pct:.1f}%)   <- extra copies beyond one-per-fingerprint')
print(f'  docs w/o log_uid  : {missing:,}  (cannot be deduped by _id; investigate separately if > 0)')
# stash the verdict for the shell via exit code: 0 = dupes, 1 = clean
sys.exit(0 if dup > 0 else 1)
" && DUPES=1 || { [ $? -eq 1 ] && DUPES=0 || DUPES=err; }

# 3) The worst offenders, with the exact index spread and a sample message body
#    so the duplication is concrete and its cause (multiple backing indices)
#    is visible. Ordered by count desc; shard_size raised for accurate top-N.
echo
echo "--- top ${TOP} most-duplicated fingerprints ---"
os "$OS_URL/${PATTERN}/_search" -d "{
  \"size\": 0,
  \"aggs\": {
    \"dups\": {
      \"terms\": {\"field\": \"attributes.log_uid\", \"size\": ${TOP}, \"min_doc_count\": 2,
                  \"order\": {\"_count\": \"desc\"}, \"shard_size\": 4000},
      \"aggs\": {
        \"by_index\": {\"terms\": {\"field\": \"_index\", \"size\": 50}},
        \"sample\":   {\"top_hits\": {\"size\": 1, \"_source\": [\"body\", \"service.name\", \"resource.attributes.service.name\", \"@timestamp\"]}}
      }
    }
  }
}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'error' in d:
    print('  ERROR:', json.dumps(d['error'])[:300]); sys.exit(2)
buckets = d['aggregations']['dups']['buckets']
if not buckets:
    print('  none — no fingerprint appears more than once'); sys.exit(0)
for b in buckets:
    spread = ', '.join('%s x%d' % (i['key'].split('-')[-1], i['doc_count'])
                       for i in b['by_index']['buckets'])
    src = (b['sample']['hits']['hits'][0].get('_source') or {})
    body = str(src.get('body', ''))[:80].replace(chr(10), ' ')
    print('  x%-3d %s...  [%s]' % (b['doc_count'], b['key'][:12], spread))
    print('        body: %s' % body)
" || true

echo
case "$DUPES" in
  1)   echo "=== VERDICT: duplicates present. See index spread above — each extra copy"
       echo "    is the same fingerprint in a different rollover backing index (replayed ingest)."
       exit 1 ;;
  0)   echo "=== VERDICT: no duplicates detected."; exit 0 ;;
  *)   echo "=== VERDICT: could not determine (query error above)."; exit 1 ;;
esac
