# observability-bootstrap

A self-contained observability stack (OpenSearch + Dashboards, Prometheus,
OpenTelemetry Collector, Data Prepper, Fluent Bit) for ingesting traces, logs and
metrics from external applications.

## Running

### Vanilla (default)

```bash
docker compose up -d
```

The stack runs ready to ingest **external** telemetry but injects **none of its
own**:

- **OTLP** traces/metrics/logs on `:4317` (gRPC) and `:4318` (HTTP) → otel-collector
- **InfoLogger** logs on the fluent-bit syslog unix socket
- forward/fluentd logs on `:24224` (fluent-bit accepts them, but no component in
  this stack pushes its own)

In this mode no component ships its container logs into the pipeline, and
Prometheus does not scrape the stack's own components — so the only data you see
is what your applications send.

### With self-monitoring (the stack observes itself)

```bash
docker compose -f docker-compose.yml -f docker-compose.self-monitoring.yml up -d
```

This overlay re-enables self-instrumentation:

- every component ships its container logs to fluent-bit via the Docker `fluentd`
  logging driver;
- Prometheus scrapes the stack's own metrics (`prometheus`, `otel-collector`,
  `data-prepper`) by mounting `prometheus/prometheus.self-monitoring.yml` instead
  of the vanilla `prometheus/prometheus.yml`.

It is also what generates the self-traffic that the `scripts/validate-*.sh`
checks assert on, so run validation with this overlay active:

```bash
docker compose -f docker-compose.yml -f docker-compose.self-monitoring.yml up -d
scripts/validate-all.sh
```
