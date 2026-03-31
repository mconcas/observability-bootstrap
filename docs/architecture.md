# Observability Bootstrap — Architecture Guide

This document explains _why_ each component exists, how data flows between them,
and what configuration choices make everything work together in OpenSearch
Dashboards (OSD) 3.6.

## The Big Picture

```
                    ┌──────────────┐
                    │  Fluent-bit  │  Tails Docker container logs
                    └──────┬───────┘
                           │ OTLP/HTTP :4318
                           ▼
┌─────────────────────────────────────────────┐
│            OpenTelemetry Collector          │
│                                             │
│  receivers: [otlp]                          │
│  connectors: [spanmetrics]                  │
│                                             │
│  pipelines:                                 │
│    traces  → Data Prepper (gRPC :21890)     │
│             + spanmetrics connector         │
│    metrics → Prometheus (OTLP/HTTP :9090)   │
│    logs    → Data Prepper (gRPC :21890)     │
└─────────────────────────────────────────────┘
        │                           │
        │ gRPC                      │ OTLP/HTTP
        ▼                           ▼
┌───────────────┐          ┌───────────────┐
│  Data Prepper │          │  Prometheus   │
│               │          │               │
│  Pipelines:   │  Prom    │  Stores:      │
│  ─ logs       │─ remote ─│  ─ RED metrics│
│  ─ traces-raw │  write   │  ─ span stats │
│  ─ svc-map    │─────────>│  ─ infra scrp │
└───────┬───────┘          └───────────────┘
        │ HTTPS :9200              │
        ▼                          │
┌───────────────┐          Direct Query
│  OpenSearch   │<─ ─ ─ ─ ─ ─ ─ ─ ┘
│  (indices)    │
└───────┬───────┘
        │
        ▼
┌────────────────────┐
│  OSD 3.6           │
│  (Discover, Traces,│
│   Application Map) │
└────────────────────┘
```

## Components and Why Each Exists

### 1. OpenTelemetry Collector (`otel-collector`)

**Role**: Central telemetry hub — receives, processes, and routes all signals.

**Self-instrumentation**: The collector instruments itself. With `service.telemetry.traces.level: detailed`,
it generates traces for every gRPC/HTTP call it makes to Data Prepper and
Prometheus. This gives us spans without needing any external application.

**Key config choices**:

- **`spanmetrics` connector**: Sits between the traces and metrics pipelines.
  It reads every span passing through and computes RED (Rate, Error, Duration)
  metrics: `traces_span_metrics_calls_total` and
  `traces_span_metrics_duration_milliseconds_*`. These are pushed to Prometheus
  via the OTLP/HTTP exporter.

- **`transform/peer_service` processor**: The collector's self-instrumented
  CLIENT spans (outbound calls to data-prepper and prometheus) only carry
  `server.address` and `server.port`. Some downstream tools expect `peer.service`
  for service-to-service relationships. This processor copies
  `server.address → peer.service` for HTTP calls and maps port 21890 → `data-prepper`
  for gRPC calls (where Go resolves the hostname to an IP before creating the span).

### 2. Data Prepper (`data-prepper`)

**Role**: Transforms OTel data into formats OpenSearch understands.

OTel Collector speaks OTLP. OpenSearch has its own index schemas for traces
and logs. Data Prepper bridges this gap with specialised processors.

**Pipelines** (defined in `pipelines.yml`):

| Pipeline | What it does |
|---|---|
| `otlp-pipeline` | Receives OTLP on port 21890, routes logs vs traces |
| `otel-logs-pipeline` | Copies `time` → `@timestamp`, writes to `logs-otel-v1*` index |
| `otel-traces-pipeline` | Fans out to `traces-raw-pipeline` and `service-map-pipeline` |
| `traces-raw-pipeline` | Converts OTLP spans → flat docs via `otel_traces` processor, writes to `otel-v1-apm-span*` |
| `service-map-pipeline` | Builds service topology via `otel_apm_service_map` processor, writes to `otel-v2-apm-service-map*` and pushes RED metrics to Prometheus via remote write |

**How `otel_apm_service_map` builds the topology**:

It builds relationships by **matching parent-child spans across different services**.
When a span in service A is the parent of a span in service B (via `parentSpanId`),
it creates an edge A → B. This means:

> A single self-instrumented service can only appear as an **isolated node**.
> To see edges (arrows) in the Application Map, you need at least two
> different `service.name` values in the same trace tree — i.e., a real
> instrumented application calling another instrumented service.

### 3. Prometheus (`prometheus`)

**Role**: Metrics storage for both infrastructure and RED metrics.

Prometheus receives metrics from three paths:

| Path | How | What |
|---|---|---|
| **Scrape: otel-collector:8888** | Pull (`/metrics`) | Collector health: `otelcol_receiver_accepted_spans`, `otelcol_exporter_sent_*`, memory, queue sizes |
| **Scrape: data-prepper:4900** | Pull (`/metrics/prometheus`) | Pipeline health: bulk errors, buffer usage, indexing latency |
| **Scrape: self** | Pull (`/metrics`) | Prometheus health: storage, query stats |
| **OTLP push from collector** | Push (OTLP/HTTP :9090) | Span RED metrics: `traces_span_metrics_calls_total`, `traces_span_metrics_duration_milliseconds_*` |
| **Remote write from Data Prepper** | Push (remote write :9090) | APM RED metrics from service-map processor |

Configuration flags that make this work:
- `--web.enable-otlp-receiver` — accepts OTLP push from the collector
- `--web.enable-remote-write-receiver` — accepts remote write from Data Prepper

### 4. OpenSearch

**Role**: Stores logs, traces, and service-map documents.

The only custom setting is:
```yaml
plugins.query.datasources.encryption.masterkey=<key>
```

This master key allows the **Direct Query** plugin to encrypt credentials when
storing external data source connections (like Prometheus). Without it, OSD
cannot register Prometheus as a data-connection and you'll get an error.

### 5. OpenSearch Dashboards (OSD 3.6)

**Role**: Visualisation layer — Discover, Traces, Application Map.

**Key `opensearch_dashboards.yml` settings**:

| Setting | Why |
|---|---|
| `workspace.enabled: true` | Enables the workspace switcher. Workspaces scope index patterns, connections, and correlations. |
| `data_source.enabled: true` | Enables the multi-data-source feature (connect to remote OpenSearch clusters + external sources). |
| `explore.enabled: true` | Enables the new Explore/Discover experience. |
| `explore.discoverTraces.enabled: true` | Shows traces signal type in Discover. |
| `explore.discoverMetrics.enabled: true` | Shows metrics signal type in Discover (for Prometheus). |
| `datasetManagement.enabled: true` | Allows managing datasets (index patterns) programmatically. |

### 6. Fluent-bit

**Role**: Collects Docker container logs and forwards as OTLP.

Tails all `*.log` files under Docker's container directory and sends them to
the OTel Collector via OTLP/HTTP on port 4318. This is how logs from
OpenSearch, Data Prepper, etc. end up in the `logs-otel-v1*` index.

**Caveat**: If the OTel Collector has a `debug` exporter (which prints to stdout),
Fluent-bit will pick up that output → send it → collector prints debug for that
→ Fluent-bit picks it up again → infinite loop. This is why the debug exporter
is removed from production pipelines.

### 7. Init Container (`opensearch-dashboards-init`)

**Role**: One-shot container that configures OSD programmatically.

OSD needs several saved objects to be created before the observability features
work correctly. The init container does this:

1. **Creates the Observability workspace** — scopes all objects to the
   observability use case
2. **Registers Prometheus** via the **Direct Query API** (`POST /api/directquery/dataconnections`)
   — NOT the data-source saved-object API (that's for additional OpenSearch clusters)
3. **Associates** the data-connection with the workspace
4. **Creates index patterns** inside the workspace (via `/w/<id>/api/saved_objects/...`):
   - `otel-v1-apm-span*` with `signalType: traces`
   - `logs-otel-v1*` with `signalType: logs` + `schemaMappings` for field naming
   - `otel-v2-apm-service-map*`
5. **Creates correlations**:
   - `trace-to-logs` — links traces ↔ logs by `traceId` so clicking a span shows related logs
   - `APM-Config` — links traces + service-map + Prometheus for the Application Map view

**Common pitfall**: The Direct Query API (`/api/directquery/dataconnections`) is
NOT the same as the data-source saved-object API (`/api/saved_objects/data-source`).
The first creates a Prometheus connection visible in Discover. The second creates
a connection to another OpenSearch cluster. Using the wrong one means Prometheus
appears nowhere in the UI.

## Data Flow: How a Trace Becomes Visible

1. OTel Collector makes a gRPC call to Data Prepper
2. Self-instrumentation creates a CLIENT span with `service.name=otelcol-contrib`
3. `transform/peer_service` processor adds `peer.service=data-prepper`
4. Span passes through the `spanmetrics` connector → RED metric counter incremented
5. Traces pipeline exports span via OTLP to Data Prepper port 21890
6. Metrics pipeline exports RED metric via OTLP/HTTP to Prometheus port 9090
7. Data Prepper `otel_traces` processor flattens span → writes to `otel-v1-apm-span-000001`
8. Data Prepper `otel_apm_service_map` buffers spans for `window_duration` (10s),
   then writes service-map docs to `otel-v2-apm-service-map-000001`
9. OSD Discover queries the `otel-v1-apm-span*` index pattern (signalType=traces)
10. OSD Traces view reads the service-map index and the APM-Config correlation to
    render the Application Map

## Signals Summary

| Signal | Index/Store | How it gets there | Visible in OSD via |
|---|---|---|---|
| Traces | `otel-v1-apm-span*` | Collector → Data Prepper → OpenSearch | Discover (signalType=traces), Traces view |
| Logs | `logs-otel-v1*` | Fluent-bit → Collector → Data Prepper → OpenSearch | Discover (signalType=logs) |
| Service Map | `otel-v2-apm-service-map*` | Data Prepper service-map processor → OpenSearch | Application Map in Traces view |
| Metrics (RED) | Prometheus | Collector spanmetrics → OTLP push to Prometheus | Discover (Prometheus data source) |
| Metrics (infra) | Prometheus | Prometheus scrapes collector, data-prepper, self | Discover (Prometheus data source) |
| Metrics (APM) | Prometheus | Data Prepper service-map → remote write to Prometheus | Discover (Prometheus data source) |

## Topology Limitations

With only self-instrumentation (no external applications), the Application Map
shows a single node (`otelcol-contrib`). This is because:

- All spans belong to the same `service.name`
- The `otel_apm_service_map` processor builds edges by matching parent→child spans
  across **different** service names
- No cross-service parent-child relationships exist in self-instrumented traces

To see a multi-node topology with edges, you need to add at least one
instrumented application that calls another (or that the collector calls).
The reference stack (`observability-stack`) achieves this with the OpenTelemetry
Demo application, which has ~15 microservices generating cross-service traces.
