#!/bin/sh
# Deploy the backend to the Railway dev project straight from this working tree, no git hook:
# `railway up` uploads the tree, Railway builds the Dockerfile, the service restarts with the
# variables it already has. Run from the repo root (once: `railway link` to the project). Prints the
# URL and waits until the new deployment, not the old one, answers /health.
set -eu
cd "$(dirname "$0")"
SERVICE=${RAILWAY_SERVICE:-backend}
OUT=$(railway up --detach --service "$SERVICE")
ID=$(printf '%s' "$OUT" | grep -oE 'id=[0-9a-f-]+' | head -1 | cut -d= -f2)
URL=$(railway domain --service "$SERVICE" --json 2>/dev/null | grep -oE 'https://[^"]+' | head -1)
echo "deployment $ID → $URL"
i=0
while [ $i -lt 60 ]; do
  if curl -sf --max-time 10 "$URL/health" | grep -q "$ID"; then echo "up: $URL"; exit 0; fi
  i=$((i + 1)); sleep 10
done
echo "not up after 10 minutes; build log:"; railway logs --service "$SERVICE" --build | tail -40; exit 1
