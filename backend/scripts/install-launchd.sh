#!/usr/bin/env bash
# Keep the backend running on this Mac (the app on the phone talks to it over Wi-Fi). Installs a
# LaunchAgent that runs serve.sh at login and restarts it if it dies. Logs: /tmp/undercurrent-backend.log
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL=com.undercurrent.backend
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GO="$(command -v go)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$PWD/scripts/serve.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(dirname "$GO"):/usr/bin:/bin:/usr/sbin:/sbin</string><key>HOME</key><string>$HOME</string></dict>
  <key>WorkingDirectory</key><string>$PWD</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/undercurrent-backend.log</string>
  <key>StandardErrorPath</key><string>/tmp/undercurrent-backend.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL; tail -f /tmp/undercurrent-backend.log"
