#!/usr/bin/env python3
"""Bootstrap OSD with workspace, Prometheus data-connection, index patterns, and correlations.

KEY CONCEPTS:

1. Workspaces: OSD 3.6 organises saved objects into workspaces.
   The Observability use-case workspace unlocks the Traces/Metrics/Logs nav.

2. Data-connections vs data-sources:
   - "data-source" (saved object)  -> additional OpenSearch clusters
   - "data-connection" (Direct Query) -> non-OpenSearch backends (Prometheus, S3...)
   Prometheus appears in the Discover data-source picker ONLY when registered
   as a data-connection via the Direct Query API AND associated with a workspace.

3. Index patterns must be created INSIDE the workspace to be visible there.

4. OpenSearch needs plugins.query.datasources.encryption.masterkey to store
   Direct Query credentials (set in docker-compose.yml on the opensearch service).
"""

import json
import os
import time
import urllib.error
import urllib.request
from base64 import b64encode
from typing import Any, cast

JsonObj = dict[str, Any]


def _obj(val: Any) -> JsonObj:
    """Narrow an Any value to a typed JSON dict (returns empty dict if not a dict)."""
    return cast(JsonObj, val) if isinstance(val, dict) else {}

OSD_URL = "http://opensearch-dashboards:5601"
USER = "admin"
PASS = os.environ.get("OPENSEARCH_PASSWORD", "MyStr0ng!Pass#2024")
PROM_NAME = "prometheus"

_AUTH_HEADER = "Basic " + b64encode(f"{USER}:{PASS}".encode()).decode()


# HTTP helpers

def req(method: str, url: str, data: dict[str, Any] | list[Any] | None = None) -> tuple[int, Any]:
    """Send an HTTP request and return (status_code, parsed_json_or_text)."""
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={
            "Authorization": _AUTH_HEADER,
            "osd-xsrf": "true",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(r) as resp:
            text = resp.read().decode()
            try:
                return resp.status, json.loads(text)
            except json.JSONDecodeError:
                return resp.status, text
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        try:
            return e.code, json.loads(text)
        except json.JSONDecodeError:
            return e.code, text


def api(path: str, ws_id: str | None = None) -> str:
    """Build a full OSD URL, optionally scoped to a workspace."""
    if ws_id:
        return f"{OSD_URL}/w/{ws_id}{path}"
    return f"{OSD_URL}{path}"


# Wait for OSD

def wait_for_osd() -> None:
    print("==> Waiting for OpenSearch Dashboards...")
    while True:
        try:
            code, _ = req("GET", f"{OSD_URL}/api/status")
            if code == 200:
                break
        except Exception:
            pass
        print("    still waiting...")
        time.sleep(5)
    print("==> OSD is up.")


# Step 1: Workspace

def find_or_create_workspace() -> str | None:
    """Find or create the Observability workspace. Returns workspace ID or None."""
    print("==> Checking for existing Observability workspace...")
    code, body = req("POST", f"{OSD_URL}/api/workspaces/_list", {})
    if code == 200:
        for ws in body.get("result", {}).get("workspaces", []):
            if ws.get("name") == "Observability":
                print(f"    Found existing workspace: {ws['id']}")
                return ws["id"]

    print("==> Creating Observability workspace...")
    code, body = req("POST", f"{OSD_URL}/api/workspaces", {
        "attributes": {
            "name": "Observability",
            "description": "Logs, traces, and metrics observability workspace",
            "features": ["use-case-observability"],
        }
    })
    ws_id: str | None = _obj(_obj(body).get("result")).get("id")
    if ws_id:
        print(f"    Created workspace: {ws_id}")
    else:
        print(f"    WARNING: could not create workspace. Continuing without workspace scoping.")
        print(f"    Response: {body}")
    return ws_id


# Step 2: Prometheus data-connection

def create_prometheus_data_connection() -> None:
    """Register Prometheus as a Direct Query data-connection."""
    print("==> Creating Prometheus data-connection...")
    code, body = req("POST", f"{OSD_URL}/api/directquery/dataconnections", {
        "name": PROM_NAME,
        "allowedRoles": [],
        "connector": "prometheus",
        "properties": {
            "prometheus.uri": "http://prometheus:9090",
            "prometheus.auth.type": "basicauth",
            "prometheus.auth.username": "",
            "prometheus.auth.password": "",
        },
    })
    if code == 200:
        print("    Created Prometheus data-connection.")
    elif "already exists" in str(body):
        print("    Prometheus data-connection already exists (OK).")
    else:
        print(f"    WARNING: HTTP {code} — {body}")


# Step 3: Associate data-connection with workspace

def associate_prometheus_with_workspace(ws_id: str) -> str | None:
    """Find the data-connection saved-object and associate it with the workspace.

    Returns the data-connection ID (needed later for APM correlation).
    """
    print(f"==> Associating Prometheus with workspace {ws_id}...")
    code, body = req("GET", f"{OSD_URL}/api/saved_objects/_find?type=data-connection&per_page=100")
    dc_id: str | None = None
    if code == 200:
        for obj in _obj(body).get("saved_objects", []):
            if _obj(_obj(obj).get("attributes")).get("connectionId") == PROM_NAME:
                dc_id = obj["id"]
                break

    if not dc_id:
        print(f"    WARNING: Could not find data-connection saved object for '{PROM_NAME}'")
        return None

    code, _ = req("POST", f"{OSD_URL}/api/workspaces/_associate", {
        "workspaceId": ws_id,
        "savedObjects": [{"type": "data-connection", "id": dc_id}],
    })
    print(f"    Association HTTP {code}")
    return dc_id


# Step 4: Index patterns

def create_index_pattern(
    title: str,
    time_field: str | None,
    signal_type: str | None = None,
    schema_mappings: str | None = None,
    ws_id: str | None = None,
) -> str | None:
    """Create (or update) an index pattern inside the workspace. Returns its saved-object ID."""
    attrs: dict[str, str] = {"title": title}
    if time_field:
        attrs["timeFieldName"] = time_field
    if signal_type:
        attrs["signalType"] = signal_type
    if schema_mappings:
        attrs["schemaMappings"] = schema_mappings

    code, body = req("POST", api("/api/saved_objects/index-pattern", ws_id), {"attributes": attrs})

    if code == 200:
        ip_id: str | None = _obj(body).get("id", "")
        print(f"    {title} -> created ({ip_id})")
        return ip_id

    # Duplicate — look up existing ID
    if "Duplicate" in str(body):
        find_url = api(
            f"/api/saved_objects/_find?type=index-pattern&search_fields=title&search={title}&per_page=10",
            ws_id,
        )
        _, found = req("GET", find_url)
        ip_id = None
        for obj in _obj(found).get("saved_objects", []):
            if _obj(_obj(obj).get("attributes")).get("title") == title:
                ip_id = obj["id"]
                break
        print(f"    {title} -> already exists ({ip_id})")

        # Update signalType / schemaMappings if needed
        if ip_id and (signal_type or schema_mappings):
            upd_attrs: dict[str, str] = {}
            if signal_type:
                upd_attrs["signalType"] = signal_type
            if schema_mappings:
                upd_attrs["schemaMappings"] = schema_mappings
            upd_code, _ = req(
                "PUT",
                api(f"/api/saved_objects/index-pattern/{ip_id}", ws_id),
                {"attributes": upd_attrs},
            )
            print(f"    {title} -> updated signalType={signal_type} (HTTP {upd_code})")
        return ip_id

    print(f"    {title} -> HTTP {code}")
    return None


# Step 5: Correlations

def create_correlation(
    corr_type: str,
    corr_title: str,
    entities: list[dict[str, Any]],
    references: list[dict[str, str]],
    ws_id: str | None = None,
) -> None:
    """Create or update a correlation saved object."""
    find_url = api("/api/saved_objects/_find?type=correlations&per_page=100", ws_id)
    _, existing = req("GET", find_url)

    # Check if one already exists (match on correlationType prefix)
    found_id: str | None = None
    prefix = "-".join(corr_type.split("-")[:2]) if "-" in corr_type else corr_type
    for obj in _obj(existing).get("saved_objects", []):
        ct: str = _obj(_obj(obj).get("attributes")).get("correlationType", "")
        if ct.startswith(prefix):
            found_id = obj["id"]
            break

    payload: dict[str, Any] = {
        "attributes": {
            "correlationType": corr_type,
            "title": corr_title,
            "version": "1.0.0",
            "entities": entities,
        },
        "references": references,
    }
    if found_id:
        code, body = req("PUT", api(f"/api/saved_objects/correlations/{found_id}", ws_id), payload)
        if code == 200:
            print(f"    {corr_title} -> updated ({found_id})")
        else:
            print(f"    {corr_title} -> update HTTP {code}: {body}")
    else:
        if ws_id:
            payload["workspaces"] = [ws_id]
        code, body = req("POST", api("/api/saved_objects/correlations", ws_id), payload)
        if code == 200:
            print(f"    {corr_title} -> created")
        else:
            print(f"    {corr_title} -> HTTP {code}: {body}")


# Main

def main() -> None:
    wait_for_osd()

    # Step 1
    ws_id = find_or_create_workspace()

    # Step 2
    create_prometheus_data_connection()

    # Step 3
    dc_id = None
    if ws_id:
        dc_id = associate_prometheus_with_workspace(ws_id)

    # Step 4 — index patterns
    print("==> Creating index patterns in workspace...")
    logs_schema = json.dumps({
        "otelLogs": {
            "timestamp": "time",
            "traceId": "traceId",
            "spanId": "spanId",
            "serviceName": "resource.attributes.service.name",
        }
    })

    logs_ip_id = create_index_pattern("logs-otel-v1*", "time", "logs", logs_schema, ws_id)
    traces_ip_id = create_index_pattern("otel-v1-apm-span*", "endTime", "traces", None, ws_id)
    svcmap_ip_id = create_index_pattern("otel-v2-apm-service-map*", "timestamp", None, None, ws_id)
    print(f"    Index pattern IDs: traces={traces_ip_id} logs={logs_ip_id} svcmap={svcmap_ip_id}")

    # Step 5 — correlations
    print("==> Creating trace-to-logs correlation...")
    if traces_ip_id and logs_ip_id:
        create_correlation(
            corr_type="trace-to-logs-otel-v1-apm-span*",
            corr_title="trace-to-logs_otel-v1-apm-span*",
            entities=[
                {"tracesDataset": {"id": "references[0].id"}},
                {"logsDataset": {"id": "references[1].id"}},
            ],
            references=[
                {"name": "entities[0].index", "type": "index-pattern", "id": traces_ip_id},
                {"name": "entities[1].index", "type": "index-pattern", "id": logs_ip_id},
            ],
            ws_id=ws_id,
        )
    else:
        print(f"    SKIP: missing index pattern IDs (traces={traces_ip_id} logs={logs_ip_id})")

    print("==> Creating APM config correlation...")
    if traces_ip_id and svcmap_ip_id and dc_id:
        create_correlation(
            corr_type=f"APM-Config-{ws_id}",
            corr_title="apm-config",
            entities=[
                {"tracesDataset": {"id": "references[0].id"}},
                {"serviceMapDataset": {"id": "references[1].id"}},
                {"prometheusDataSource": {"id": "references[2].id"}},
            ],
            references=[
                {"name": "entities[0].index", "type": "index-pattern", "id": traces_ip_id},
                {"name": "entities[1].index", "type": "index-pattern", "id": svcmap_ip_id},
                {"name": "entities[2].dataConnection", "type": "data-connection", "id": dc_id},
            ],
            ws_id=ws_id,
        )
    else:
        print(f"    SKIP: missing IDs (traces={traces_ip_id} svcmap={svcmap_ip_id} dc={dc_id})")

    print("==> Init complete.")
    print(f"    Workspace: {ws_id or 'none'}")
    print(f"    Prometheus: {PROM_NAME} (Direct Query)")
    print(f"    Correlations: trace-to-logs + APM-Config")
    print(f"    Navigate to: http://localhost:5601/w/{ws_id}/app/observability-traces")


if __name__ == "__main__":
    main()
