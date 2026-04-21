#!/usr/bin/env python3
"""
service-map link enricher — fan-in edge detector

Detects missing B→D edges in DPL diamond topologies (A→B, A→C, B→D, C→D)
that Data-Prepper's otel_apm_service_map processor cannot derive because:

  - The DPL SDK propagates only one W3C traceparent to D (from C), not from B.
  - The DPL SDK does NOT generate OTLP span links.

Strategy: SERVER-parented orphaned CLIENT detection
  1. Find SERVER dpl/process spanIds in the extended lookback window
     (used to identify which CLIENT spans are "nested" — their parent is a
     SERVER span, meaning they represent intra-topology sends, not root sends).
  2. Find CLIENT dpl/send spans whose parentSpanId is a SERVER span AND that
     are old enough for their expected SERVER-child to have arrived (MIN_AGE).
     This excludes root-level CLIENT spans (e.g. A's dpl/process children)
     which have a CLIENT parent and are not fan-in sources.
  3. Determine which of those CLIENT spans have a child SERVER span
     (parentSpanId match in the span index). These are already captured
     by Data-Prepper and are NOT orphaned.
  4. Remaining CLIENT spans with no child SERVER = "orphaned fan-in sources".
  5. For each trace with orphaned CLIENT spans, fetch ALL CLIENT and SERVER
     dpl/* spans in that trace (no time limit) to correctly identify leaf
     services (services that receive but never send in this trace).
  6. Upsert service-map edges: orphaned_source → leaf_service.
"""

import hashlib
import json
import os
import time
import urllib.request
from datetime import datetime, timezone
from typing import Any, cast

OPENSEARCH_URL        = os.environ.get("OPENSEARCH_URL",             "http://opensearch:9200")
INTERVAL              = int(os.environ.get("ENRICH_INTERVAL_SECONDS", "30"))
LOOKBACK_MINUTES      = int(os.environ.get("LOOKBACK_MINUTES",        "30"))
PROCESSING_BUFFER_MIN = int(os.environ.get("PROCESSING_BUFFER_MIN",   "10"))
MIN_AGE_MINUTES       = int(os.environ.get("MIN_AGE_MINUTES",          "10"))
ENVIRONMENT           = os.environ.get("DPL_ENVIRONMENT",            "generic:default")

SPAN_INDEX    = "otel-v1-apm-span-000001"
SVC_MAP_INDEX = "otel-v2-apm-service-map-000001"
PAGE_SIZE     = 2000
TERMS_BATCH   = 8000


def _request(method: str, path: str, body: Any = None) -> Any:
    url = f"{OPENSEARCH_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def _scroll_all(query_body: dict) -> list[dict]:
    """Return all _source dicts matching query_body, handling scroll pagination."""
    resp = _request("POST", f"/{SPAN_INDEX}/_search?scroll=1m",
                    {**query_body, "size": PAGE_SIZE})
    scroll_id = resp.get("_scroll_id")
    results: list[dict] = []
    hits = resp.get("hits", {}).get("hits", [])
    while hits:
        results.extend(h["_source"] for h in hits)
        if len(hits) < PAGE_SIZE:
            break
        resp = _request("POST", "/_search/scroll",
                        {"scroll": "1m", "scroll_id": scroll_id})
        scroll_id = resp.get("_scroll_id")
        hits = resp.get("hits", {}).get("hits", [])
    if scroll_id:
        try:
            _request("DELETE", "/_search/scroll", {"scroll_id": scroll_id})
        except Exception:
            pass
    return results


def _bulk(ndjson_lines: list[str]) -> None:
    body = ("\n".join(ndjson_lines) + "\n").encode()
    req = urllib.request.Request(
        f"{OPENSEARCH_URL}/_bulk", data=body, method="POST")
    req.add_header("Content-Type", "application/x-ndjson")
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = cast(dict, json.loads(r.read()))
    if resp.get("errors"):
        for item in resp.get("items", []):
            if not isinstance(item, dict):
                continue
            op = item.get("index") or item.get("create") or {}
            if isinstance(op, dict) and op.get("error"):
                print(f"[WARN] bulk error: {op['error']}", flush=True)


def _stable_hash(key: str) -> str:
    return str(int(hashlib.md5(key.encode()).hexdigest()[:8], 16) % 10**9)


def _minute_bucket(iso_ts: str) -> str:
    if not iso_ts:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:00Z")
    return iso_ts[:16] + ":00Z"


def _svcmap_pure_leaves() -> set[str]:
    """
    Return service names that appear as targetNode but never as sourceNode in the
    existing service-map.  These are the true leaf / fan-in services (e.g. D in
    A→B, A→C, B→D, C→D).  We restrict fan-in edge creation to these services to
    avoid false edges to intermediate services that are merely transient leaves in
    incomplete traces.
    """
    try:
        resp = _request("POST", f"/{SVC_MAP_INDEX}/_search", {
            "size": 0,
            "aggs": {
                "sources": {"terms": {"field": "sourceNode.keyAttributes.name",
                                      "size": 100}},
                "targets": {"terms": {"field": "targetNode.keyAttributes.name",
                                      "size": 100}}
            }
        })
        sources = {b["key"] for b in
                   resp["aggregations"]["sources"]["buckets"]}
        targets = {b["key"] for b in
                   resp["aggregations"]["targets"]["buckets"]}
        return targets - sources
    except Exception as e:
        print(f"[WARN] could not read service-map leaves: {e}", flush=True)
        return set()


def enrich() -> int:
    # CLIENT spans checked in [now-LOOKBACK_MINUTES, now-MIN_AGE_MINUTES].
    # The MIN_AGE guard ensures the expected SERVER-child has had time to arrive.
    client_since = f"now-{LOOKBACK_MINUTES}m"
    client_until = f"now-{MIN_AGE_MINUTES}m"
    # SERVER spans searched over a wider window to catch slow processors.
    server_since  = f"now-{LOOKBACK_MINUTES + PROCESSING_BUFFER_MIN}m"

    # Determine which services are true leaves in the existing service-map.
    # Only these are valid fan-in targets; this prevents false edges to
    # intermediate services that happen to be transient leaves in incomplete traces.
    pure_leaves = _svcmap_pure_leaves()
    if not pure_leaves:
        # Service-map not yet populated; skip this cycle.
        return 0

    # --- Step 0: collect SERVER dpl/process spanIds for parent-kind filter ------
    # A CLIENT dpl/send whose parent is another CLIENT (e.g. A's root dpl/process)
    # is NOT a fan-in source. Only CLIENT spans whose parent is a SERVER span are.
    server_spanids: set[str] = set()
    for src in _scroll_all({
        "_source": ["spanId"],
        "query": {"bool": {"must": [
            {"term":  {"kind": "SPAN_KIND_SERVER"}},
            {"term":  {"name": "dpl/process"}},
            {"range": {"startTime": {"gte": server_since}}}
        ]}}
    }):
        sid = src.get("spanId", "")
        if sid:
            server_spanids.add(sid)

    if not server_spanids:
        return 0

    # --- Step 1: CLIENT dpl/send spans whose parent IS a SERVER span ------------
    # This restricts candidates to "nested" CLIENT spans (B CLIENT, C CLIENT),
    # excluding root-level CLIENT spans like A's dpl/send children.
    client_by_sid: dict[str, dict] = {}
    trace_to_client_svcs: dict[str, set] = {}

    server_sid_list = list(server_spanids)
    for i in range(0, len(server_sid_list), TERMS_BATCH):
        batch = server_sid_list[i : i + TERMS_BATCH]
        for src in _scroll_all({
            "_source": ["spanId", "serviceName", "traceId", "startTime"],
            "query": {"bool": {"must": [
                {"term":  {"kind": "SPAN_KIND_CLIENT"}},
                {"term":  {"name": "dpl/send"}},
                {"terms": {"parentSpanId": batch}},
                {"range": {"startTime": {"gte": client_since, "lte": client_until}}}
            ]}}
        }):
            sid = src.get("spanId", "")
            svc = src.get("serviceName", "")
            tid = src.get("traceId", "")
            if not (sid and svc and tid):
                continue
            client_by_sid[sid] = {"svc": svc, "traceId": tid,
                                   "ts": src.get("startTime", "")}
            trace_to_client_svcs.setdefault(tid, set()).add(svc)

    if not client_by_sid:
        return 0

    # --- Step 2: find which CLIENT spans have a child SERVER span ---------------
    has_server_child: set[str] = set()
    trace_to_server_svcs: dict[str, set] = {}

    client_ids = list(client_by_sid)
    for i in range(0, len(client_ids), TERMS_BATCH):
        batch = client_ids[i : i + TERMS_BATCH]
        for src in _scroll_all({
            "_source": ["parentSpanId", "serviceName", "traceId"],
            "query": {"bool": {"must": [
                {"term":  {"kind": "SPAN_KIND_SERVER"}},
                {"term":  {"name": "dpl/process"}},
                {"terms": {"parentSpanId": batch}},
                {"range": {"startTime": {"gte": server_since}}}
            ]}}
        }):
            psid = src.get("parentSpanId", "")
            svc  = src.get("serviceName", "")
            tid  = src.get("traceId", "")
            if psid:
                has_server_child.add(psid)
            if svc and tid:
                trace_to_server_svcs.setdefault(tid, set()).add(svc)

    # --- Step 3: identify orphaned CLIENT spans ---------------------------------
    orphaned_by_trace: dict[str, list[tuple[str, str]]] = {}

    for sid, info in client_by_sid.items():
        if sid in has_server_child:
            continue
        tid = info["traceId"]
        orphaned_by_trace.setdefault(tid, []).append((info["svc"], info["ts"]))

    if not orphaned_by_trace:
        return 0

    # --- Step 4: complete service sets for orphaned traces ----------------------
    # Fetch ALL CLIENT and SERVER dpl/* spans for these traces (no time filter)
    # to correctly identify leaf services even when some spans predate the window.
    orphaned_trace_ids = list(orphaned_by_trace)
    for i in range(0, len(orphaned_trace_ids), TERMS_BATCH):
        batch = orphaned_trace_ids[i : i + TERMS_BATCH]
        # 4a: SERVER spans
        for src in _scroll_all({
            "_source": ["serviceName", "traceId"],
            "query": {"bool": {"must": [
                {"term":  {"kind": "SPAN_KIND_SERVER"}},
                {"term":  {"name": "dpl/process"}},
                {"terms": {"traceId": batch}}
            ]}}
        }):
            svc = src.get("serviceName", "")
            tid = src.get("traceId", "")
            if svc and tid:
                trace_to_server_svcs.setdefault(tid, set()).add(svc)
        # 4b: CLIENT spans — completes trace_to_client_svcs regardless of age
        for src in _scroll_all({
            "_source": ["serviceName", "traceId"],
            "query": {"bool": {"must": [
                {"term":  {"kind": "SPAN_KIND_CLIENT"}},
                {"term":  {"name": "dpl/send"}},
                {"terms": {"traceId": batch}}
            ]}}
        }):
            svc = src.get("serviceName", "")
            tid = src.get("traceId", "")
            if svc and tid:
                trace_to_client_svcs.setdefault(tid, set()).add(svc)

    # --- Step 5: compute leaf services and emit edges ---------------------------
    # Leaf = has SERVER dpl/process spans in trace but no CLIENT dpl/send spans.
    seen: set[tuple[str, str]] = set()
    bulk_lines: list[str] = []

    for tid, orphaned_entries in orphaned_by_trace.items():
        client_svcs = trace_to_client_svcs.get(tid, set())
        server_svcs = trace_to_server_svcs.get(tid, set())
        leaf_svcs   = server_svcs - client_svcs

        if not leaf_svcs:
            continue

        for (orphan_svc, ts) in orphaned_entries:
            for leaf_svc in leaf_svcs:
                if leaf_svc == orphan_svc:
                    continue
                # Only target services that are pure leaves in the established
                # service-map topology (appear as target but never as source).
                if leaf_svc not in pure_leaves:
                    continue
                edge = (orphan_svc, leaf_svc)
                if edge in seen:
                    continue
                seen.add(edge)

                doc_id = f"fanin-edge-{orphan_svc}-{leaf_svc}"
                doc: dict[str, Any] = {
                    "sourceNode": {
                        "type": "service",
                        "keyAttributes": {
                            "environment": ENVIRONMENT, "name": orphan_svc},
                        "groupByAttributes": {}
                    },
                    "targetNode": {
                        "type": "service",
                        "keyAttributes": {
                            "environment": ENVIRONMENT, "name": leaf_svc},
                        "groupByAttributes": {}
                    },
                    "sourceOperation": {"name": "dpl/send",    "attributes": {}},
                    "targetOperation": {"name": "dpl/process", "attributes": {}},
                    "nodeConnectionHash":      _stable_hash(f"{orphan_svc}->{leaf_svc}"),
                    "operationConnectionHash": _stable_hash("dpl/send->dpl/process"),
                    "timestamp": _minute_bucket(ts)
                }
                bulk_lines.append(json.dumps(
                    {"index": {"_index": SVC_MAP_INDEX, "_id": doc_id}}))
                bulk_lines.append(json.dumps(doc))

    if bulk_lines:
        _bulk(bulk_lines)

    return len(seen)


def wait_for_opensearch() -> None:
    print("[INFO] waiting for OpenSearch …", flush=True)
    while True:
        try:
            health = _request("GET", "/_cluster/health")
            status = health.get("status", "unknown")
            if status in ("green", "yellow"):
                print(f"[INFO] OpenSearch is up (status={status})", flush=True)
                return
            print(f"[INFO] OpenSearch status={status}, retrying …", flush=True)
        except Exception as e:
            print(f"[INFO] OpenSearch not ready: {e}", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    print(
        f"[INFO] service-map-enricher starting "
        f"(interval={INTERVAL}s, lookback={LOOKBACK_MINUTES}m, "
        f"min_age={MIN_AGE_MINUTES}m, buffer={PROCESSING_BUFFER_MIN}m)",
        flush=True,
    )
    wait_for_opensearch()
    while True:
        try:
            n = enrich()
            if n:
                print(f"[INFO] upserted {n} fan-in service-map edge(s)", flush=True)
        except Exception as e:
            print(f"[ERROR] {e}", flush=True)
        time.sleep(INTERVAL)
