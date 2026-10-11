# mobile-app

The native iOS app (SwiftUI, iOS 17) for the board. It talks to the Go backend over HTTP
(`../backend/API.md`) and never opens the database. The spec is `../MOBILE_APP.md`; the look is
`DESIGN.md`.

Built on the same XcodeGen + Fastlane + match pipeline as `~/Developer/mobile-dev`: the
`.xcodeproj` is generated from `project.yml` — never edit it directly.

## Layout

```
project.yml                  the Xcode project (XcodeGen); BACKEND_URL is the build default
Sources/Undercurrent/
  UndercurrentApp.swift      entry; refreshes the board whenever the app comes to the front
  Design/                    Theme (tokens) and Components (the qoves-style pieces)
  Models/                    BoardTask, Event, Run (API.md as Swift); Insights (the stats engine)
  API/                       Backend (the HTTP client); MockBackend (in-process, for tests/previews)
  Store/Board.swift          the board: fetched on focus and after every action
  Views/                     Home, TaskDetail (+StageSheet), Add, Closed, Retransform, Run, Call,
                             Insights, Settings
Tests/UndercurrentTests      unit: decoding, insights, client + board against the mock
Tests/UndercurrentUITests    UI smoke tests, launched with -mockBackend; screenshots in the xcresult
scripts/                     setup · test · deploy_phone · ship · make_icon
fastlane/                    beta lane → TestFlight (bundle com.hebbarpran.undercurrent)
```

## Run

```sh
./scripts/setup.sh                      # xcodegen + gems
./scripts/test.sh                       # unit + UI tests on the simulator (mock backend)
open Undercurrent.xcodeproj             # run on the simulator; it reads BACKEND_URL from project.yml
```

The backend: `../backend/scripts/serve.sh` (the shared Turso board, from `../.env`) or
`../backend/scripts/serve-local.sh` (a throwaway file database with the demo set, on :8788 (the shared one is on :8790, set in ../.env)).
The app's Settings screen can point at either.

## On the phone, today

```sh
cp scripts/.env.local.example scripts/.env.local   # this Mac, this phone, the ad-hoc identity (gitignored)
./scripts/deploy_phone.sh
```

Builds a Release app, signs it with an ad-hoc profile already on this Mac, installs it over
USB / Wi-Fi with `devicectl`, and retries for five minutes while you unlock the phone. Shipping
under a bundle id you already have an ad-hoc profile for (set `BUNDLE_ID` and `PROFILE` in
`.env.local`) needs no Apple round-trip at all; it replaces that app on the phone. The first run may
ask for one keychain click (**Always Allow**).

The phone reaches the backend at `BACKEND_URL` from `.env.local` (your Mac's `.local` name on the
same Wi-Fi). The app's Settings screen can change it later.

## Voice

The Call screen is a real ElevenLabs conversation (their Swift SDK over WebRTC). The app asks the
backend for a conversation token (`GET /live/signed-url`), so no key ships in the app; the agent's
tools call the backend back through a tunnel. Setting up or re-pointing the agent, from `../backend`:

```sh
cloudflared tunnel --url http://127.0.0.1:8790     # put the https URL in ../.env as PUBLIC_URL
go run ./cmd/undercurrent elevenlabs sync          # creates/updates the tools and the agent (ids in the meta table)
../backend/scripts/serve.sh                        # restart so the backend reads the new .env
```

A quick tunnel's URL changes every time it restarts; run `elevenlabs sync` again after that.
Launching the app with `-call` opens the Call screen at once (handy on the simulator:
`xcrun simctl launch <udid> com.hebbarpran.undercurrent -backendURL http://127.0.0.1:8790 -call`).

## TestFlight, later

`./scripts/ship.sh` runs `fastlane beta` under `com.hebbarpran.undercurrent`. Before the first ship:
accept the current Apple Developer agreement (the ASC API answers 403
`REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` until you do), register the App ID, create the app in
App Store Connect, `bundle exec fastlane setup_signing`.

## Testing

UI tests never touch a real database: `-mockBackend` installs a `URLProtocol` that serves API.md
from memory (`API/MockBackend.swift`), with a fixture of ten tasks and one run. Unit tests cover
the models, the Insights engine, the client's error mapping (404 → notFound, 409 → refused,
501 → notBuilt), and the Board's refresh-after-every-action rule.
