#!/usr/bin/env bash
# Run all validation skills and produce a summary
set -uo pipefail

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0

for skill in \
  validate-fluent-bit.sh \
  validate-opensearch.sh \
  validate-prometheus.sh \
  validate-data-prepper.sh \
  validate-otel-collector.sh \
  validate-opensearch-dashboards.sh \
  validate-data-flow.sh; do

  echo ""
  bash "$SKILLS_DIR/$skill"
  rc=$?
  if [ $rc -eq 0 ]; then
    ((TOTAL_PASS++))
  else
    ((TOTAL_FAIL++))
  fi
done

echo ""
echo "========================================"
echo "  All skills: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "========================================"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
