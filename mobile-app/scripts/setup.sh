#!/usr/bin/env bash
# Run once after cloning: tools, gems, the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen
eval "$(rbenv init - zsh 2>/dev/null || true)"
bundle install --quiet
xcodegen generate
echo "Open Undercurrent.xcodeproj, or: ./scripts/test.sh"
