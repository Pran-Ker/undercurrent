#!/usr/bin/env bash
# Run the backend against the database named in ../.env (the shared Turso board by default).
# Never runs `seed`: that is for a local file database only.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source ../.env; set +a
exec go run ./cmd/undercurrent serve
