#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SLAVE_ACCEPTANCE_REPO="${SLAVE_ACCEPTANCE_REPO:-alt-claude-slave-acceptance}"
exec bash "$ROOT/diagnostics/verify-mcp-worker.sh" "$@"
