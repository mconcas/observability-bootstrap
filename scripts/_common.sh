#!/usr/bin/env bash
# Shared helpers for validation skills
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0

# Load password from .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENSEARCH_PASSWORD=$(grep '^OPENSEARCH_PASSWORD=' "$REPO_ROOT/.env" | cut -d= -f2-)

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

check_container_running() {
  local name="$1"
  local state
  state=$(docker inspect --format='{{.State.Running}}' "$name" 2>/dev/null || echo "false")
  [ "$state" = "true" ] && pass "$name container running" || fail "$name container not running"
}

summary() {
  echo ""
  echo "=== Result: $PASS_COUNT passed, $FAIL_COUNT failed ==="
  [ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
}
