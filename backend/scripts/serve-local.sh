#!/usr/bin/env bash
# Run the backend on a throwaway local file database with the demo set, for testing the app
# without touching the shared board. PORT defaults to 8788 so it can sit next to the real one.
set -euo pipefail
cd "$(dirname "$0")/.."
export UNDERCURRENT_DB="${UNDERCURRENT_DB:-file:/tmp/undercurrent-local.db}"
export PORT="${PORT:-8788}"
unset TURSO_DATABASE_URL TURSO_AUTH_TOKEN
go run ./cmd/undercurrent seed
exec go run ./cmd/undercurrent serve
