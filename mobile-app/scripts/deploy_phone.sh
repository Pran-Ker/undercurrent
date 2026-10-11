#!/bin/zsh
# Ad-hoc deploy straight to the iPhone, no TestFlight: build Release, sign with the ad-hoc profile
# already on this Mac, install over USB / Wi-Fi with devicectl. Everything about this machine and
# this phone comes from scripts/.env.local (gitignored; see .env.local.example).
#
#   ./scripts/deploy_phone.sh
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

[[ -f scripts/.env.local ]] || { echo "✗ copy scripts/.env.local.example to scripts/.env.local and fill it in"; exit 1; }
set -a; source scripts/.env.local; set +a
for v in DEVICE_UUID BUNDLE_ID PROFILE IDENTITY APPLE_TEAM_ID BACKEND_URL; do
  [[ -n "${(P)v:-}" ]] || { echo "✗ $v is not set in scripts/.env.local"; exit 1; }
done
TEAM="$APPLE_TEAM_ID"
OUT="/tmp/undercurrent-device"
APP="$OUT/Build/Products/Release-iphoneos/Undercurrent.app"
PROFILE_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE.mobileprovision"

[[ -f "$PROFILE_PATH" ]] || { echo "✗ no profile at $PROFILE_PATH"; exit 1; }

xcodegen generate >/dev/null
echo "→ Building Release for device…"
xcodebuild build -project Undercurrent.xcodeproj -scheme Undercurrent -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$OUT" -quiet \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" BACKEND_URL="$BACKEND_URL" BACKEND_KEY="${BACKEND_KEY:-}" CODE_SIGNING_ALLOWED=NO

echo "→ Signing (click 'Always Allow' if the keychain asks)…"
cat > /tmp/undercurrent-ent.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><false/>
</dict></plist>
PLIST
cp "$PROFILE_PATH" "$APP/embedded.mobileprovision"
# Nested frameworks (LiveKit, from the ElevenLabs SDK) are signed first, then the app on top.
if [[ -d "$APP/Frameworks" ]]; then
  for fw in "$APP"/Frameworks/*.framework "$APP"/Frameworks/*.dylib; do
    [[ -e "$fw" ]] || continue
    codesign -f -s "$IDENTITY" "$fw"
  done
fi
codesign -f -s "$IDENTITY" --entitlements /tmp/undercurrent-ent.plist "$APP"
codesign --verify --strict "$APP"
echo "✓ Signed as $BUNDLE_ID"

echo "→ Installing (unlock the iPhone; same Wi-Fi or USB)…"
for i in {1..60}; do
  if xcrun devicectl device install app --device "$DEVICE_UUID" "$APP" >/tmp/undercurrent-install.log 2>&1; then
    echo "✓ Undercurrent is on your phone."
    exit 0
  fi
  sleep 5
done
echo "✗ iPhone not reachable after 5 min:"; tail -3 /tmp/undercurrent-install.log
exit 1
