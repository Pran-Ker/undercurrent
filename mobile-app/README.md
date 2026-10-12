# mobile-app

The native iOS app (SwiftUI, iOS 17) for the board. It talks to the Go backend over HTTP
(`../backend/API.md`) and never opens the database. The spec is `../MOBILE_APP.md`; the look is
`DESIGN.md`.

Built on the same XcodeGen + Fastlane + match pipeline as `~/Developer/mobile-dev`: the
`.xcodeproj` is generated from `project.yml`: never edit it directly.

## Layout

```
project.yml                  the Xcode project (XcodeGen); BACKEND_URL and BACKEND_KEY are the build defaults
Sources/Undercurrent/
  UndercurrentApp.swift      entry; refreshes the board whenever the app comes to the front
  Design/                    Theme (tokens) and Components (the qoves-style pieces)
  Models/                    BoardTask, Event, Run (API.md as Swift); Insights (the stats engine)
  API/                       Backend (the HTTP client); MockBackend (in-process, for tests/previews)
  Store/Board.swift          the board: fetched on focus and after every action; polls while a task is committed
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

## The key

A backend started with `UNDERCURRENT_API_KEY` (always, on a public URL) answers 401 to everything but
`GET /health` unless the request carries `Authorization: Bearer <key>` (`MOBILE_APP.md`, "Reaching the
backend"). The app sends the key on every request. Where it comes from, in order:

1. The **Key** field in Settings (stored as `backendKey` in UserDefaults; `-backendKey <key>` on the
   command line lands in the same place, like `-backendURL`).
2. The build default `BACKEND_KEY` (`project.yml` → `BackendKey` in Info.plist), empty in the repo;
   `deploy_phone.sh` passes it from `scripts/.env.local`.

**Check** in Settings hits `/health` and then `/tasks`, so a wrong key shows the backend's 401 message
before you use it. Home shows "This backend needs its key. Set it in Settings." when a keyed backend
refuses the board. To try it on the simulator:

```sh
cd ../backend && UNDERCURRENT_API_KEY=testkey PORT=8831 UNDERCURRENT_DB=file:/tmp/uc-auth.db ./scripts/serve-local.sh
xcrun simctl launch <udid> com.hebbarpran.undercurrent -backendURL http://127.0.0.1:8831 -backendKey testkey
```

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

The Call screen is a real ElevenLabs conversation (their Swift SDK over WebRTC). Before a call the
app asks the backend for `GET /live/config` (the agent, the tool secret, the tool names, the board
as text) and `GET /live/signed-url` (the conversation token), so no ElevenLabs key ships in the app.
The agent's tools are **client tools**: ElevenLabs hands each call to the phone, `LiveSession`
forwards it to `POST /live/tools/<name>` with the secret, returns the result for the agent to speak,
and refreshes the board. Key actions come back as a read-back first; the card shows it with Yes / No.
When the call ends the transcript goes to `POST /live/post-call`. The backend needs no public URL.

Setting up or re-pointing the agent, from `../backend` (the ids live in the database's meta table):

```sh
go run ./cmd/undercurrent elevenlabs sync          # creates/updates the ten client tools and the agent
../backend/scripts/serve.sh                        # restart so the backend reads the new .env
```

Launching with `-call` opens the Call screen at once; `-say "<text>"` types one line to the agent
once it has greeted (handy on the simulator, where the microphone is the Mac's):
`xcrun simctl launch <udid> com.hebbarpran.undercurrent -backendURL http://127.0.0.1:8790 -call`.

## TestFlight, later

`./scripts/ship.sh` runs `fastlane beta` under `com.hebbarpran.undercurrent`. Before the first ship:
accept the current Apple Developer agreement (the ASC API answers 403
`REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` until you do), register the App ID, create the app in
App Store Connect, `bundle exec fastlane setup_signing`.

## Testing

UI tests never touch a real database: `-mockBackend` installs a `URLProtocol` that serves API.md
from memory (`API/MockBackend.swift`), with a fixture of ten tasks and one run that needs you. The
mock's agent moves one step each time the runs are read, the way the real one moves between two
polls: commit queues a run that asks a question on the next `GET /runs`; an answer resumes it and
on the next read it closes the task with a note and yields the next step unstaged with `parent_id`;
retransform answers `{run, say}` and appends the instruction to the context. `MockBackend.requiredKey`
makes it answer 401 like a keyed backend. Only `GET /live/signed-url` is still 501 in the mock.
Unit tests cover the models (including the run's step objects and `cost_cents`), the Insights
engine, the client's error mapping (401 → unauthorized, 404 → notFound, 409 → refused,
501 → notBuilt), the key header, the Board's refresh-after-every-action rule and its polling.
