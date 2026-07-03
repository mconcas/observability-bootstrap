#!/usr/bin/env bash
# deploy.sh — deploy a named configuration of the observability stack.
#
# A "configuration" is a named set of docker-compose overlay files layered on
# top of the bare base (docker-compose.yml). Pick one as the first argument;
# every argument after it is passed straight through to `docker compose`
# (default subcommand: `up -d`).
#
#   ./deploy.sh bare                  # most vanilla: base only, no init script
#   ./deploy.sh default               # base + Dashboards init (data source + index patterns)
#   ./deploy.sh self-monitoring       # default + the stack observes itself
#   ./deploy.sh self-monitoring down  # any compose subcommand passes through
#   ./deploy.sh default logs -f opensearch
#
# Add a new configuration by giving it an entry in the case statement below.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIGS="bare default self-monitoring"

usage() {
  cat <<EOF
Usage: $(basename "$0") <configuration> [docker compose args...]

Configurations:
  bare              Base only — no init script, no self-monitoring (most vanilla).
  default           Base + Dashboards init (registers data source + index patterns).
  self-monitoring   Default + the stack ships its own logs and scrapes its own metrics.

Anything after the configuration name is forwarded to 'docker compose'.
If no compose subcommand is given, 'up -d' is used.

Examples:
  $(basename "$0") bare
  $(basename "$0") default
  $(basename "$0") self-monitoring down
EOF
}

config="${1:-}"
if [ -z "$config" ] || [ "$config" = "-h" ] || [ "$config" = "--help" ]; then
  usage
  [ -z "$config" ] && exit 1 || exit 0
fi
shift

# Map a configuration name to its layered compose files.
case "$config" in
  bare)
    files=(-f docker-compose.yml)
    ;;
  default)
    files=(-f docker-compose.yml -f docker-compose.init.yml)
    ;;
  self-monitoring)
    files=(-f docker-compose.yml -f docker-compose.init.yml -f docker-compose.self-monitoring.yml)
    ;;
  *)
    echo "Unknown configuration: '$config' (known: $CONFIGS)" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac

# Default to bringing the stack up if no compose subcommand was supplied.
if [ "$#" -eq 0 ]; then
  set -- up -d
fi

echo "Configuration: $config" >&2
echo "Compose files:${files[*]/#-f/ }" >&2
echo "+ docker compose ${files[*]} $*" >&2
exec docker compose "${files[@]}" "$@"
