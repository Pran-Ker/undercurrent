#!/usr/bin/env bash
# Ship to TestFlight. Needs ~/.local/secrets-extra (ASC key, match) and the App ID + ASC app to exist.
set -euo pipefail
cd "$(dirname "$0")/.."
source ~/.local/secrets-extra
eval "$(rbenv init - zsh)"
xcodegen generate
bundle exec fastlane beta
