# Observability Bootstrap

Minimal, self-contained observability stack for OpenSearch Dashboards 3.6.
Ships logs, traces, and metrics with zero external applications — the OTel
Collector's self-instrumentation generates all telemetry.

## Components

| Service | Role |
|---|---|
| **Fluent-Bit** | Receives Docker container logs via the fluentd logging driver, forwards as OTLP to the collector |
| **OTel Collector** | Central hub — receives, processes, and routes all signals; self-instruments to generate traces |
| **Data Prepper** | Transforms OTLP into OpenSearch index formats (traces, logs, service-map) |
| **Prometheus** | Stores RED metrics (from spanmetrics), APM metrics (from Data Prepper), and infra scrapes |
| **OpenSearch** | Stores trace spans, logs, and service-map documents |
| **OSD (Dashboards)** | Visualisation — Discover, Traces, Application Map |
| **Init container** | One-shot setup: creates workspace, Prometheus data-connection, index patterns, and correlations in OSD |

## Prerequisites

- Docker and Docker Compose v2
- ~4 GB free RAM (OpenSearch JVM alone uses 2 GB)

## Quick start

```bash
docker compose up -d
```

All versions and the admin password are configured in `.env`.

Wait ~60 seconds for OpenSearch to become healthy and the init container to
finish, then open:

- **OpenSearch Dashboards**: http://localhost:5601 (admin / `MyStr0ng!Pass#2024`)
- **Prometheus**: http://localhost:9090
- **OpenSearch API**: https://localhost:9200

## Validate

Run the validation skills to check every service and data flow:

```bash
bash .skills/validate-all.sh
```

Or validate a single service:

```bash
bash .skills/validate-opensearch.sh
bash .skills/validate-data-flow.sh
```

## Stop

```bash
docker compose down
```

Add `-v` to also remove persisted data (OpenSearch indices, Prometheus TSDB).

## Architecture

See [docs/architecture.md](docs/architecture.md) for a detailed walkthrough of
components, data flow, and configuration rationale.
