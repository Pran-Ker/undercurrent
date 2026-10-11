#!/usr/bin/env bash
# Build and run every test (unit + UI) on the simulator. UI tests run against the in-process mock
# backend (-mockBackend), never against a real database.
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${SIM:-iPhone 17 Pro}"
xcodegen generate >/dev/null
xcodebuild test -project Undercurrent.xcodeproj -scheme Undercurrent \
  -destination "platform=iOS Simulator,name=$SIM" -quiet "$@"
