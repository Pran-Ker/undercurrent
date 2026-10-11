# undercurrent

A voice-first personal agent for the things you have to do. You write tasks down; you stage the
ones you mean by adding context; you commit a staged task to an agent, or retransform it in a
conversation, or close it yourself. A live voice agent can do all of that on your word, reading
back anything that matters before it happens. Every move is an event, so the board can be shown as
it was at any moment and read as who-did-what.

## Layout

```
backend/            Go. The board, the API, the runs, the live agent's tools, the event log.
  cmd/undercurrent  the binary: serve · migrate · seed
  internal/store    the database (a local file, or Turso) and the migrations
  internal/api      the HTTP surface — see API.md
  internal-web-ui/  the internal board, a static page served by the backend
  elevenlabs/       the live agent's configuration (phase 2)
  db/               schema.sql, migrations/, demo.sql (42 demo tasks)
  API.md            the contract the app and the UI are written against
mobile-app/         SwiftUI (iOS 17), XcodeGen + Fastlane. See MOBILE_APP.md for what it is; its README for how to run and ship.
MOBILE_APP.md       the app, screen by screen
TESTING.md          the integration tests, one diagram each
SUGGESTIONS.md      what the references teach, and what to borrow
```

## Run

```sh
cp .env.example .env            # a local file database by default
cd backend
go run ./cmd/undercurrent seed  # migrate + the demo set
go run ./cmd/undercurrent serve # http://127.0.0.1:8787 — the board at /, the API at /tasks
go test ./...
```

Point `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` at the shared database instead to work on the
same board. `backend/scripts/serve.sh` does that from `.env` (never `seed` against it);
`backend/scripts/serve-local.sh` runs a throwaway file database with the demo set on :8788;
`backend/scripts/install-launchd.sh` keeps the shared-board backend running on this Mac for the app.

## Lifecycle

`unstaged` (written down) → `staged` (context added) → `committed` (an agent is on it) → `closed`.
A staged task can be retransformed — rewritten, enriched, split, or completed with the next step
yielded. Closing and editing never need an agent. There is no erase.

The agent is the owner's secretary, and there is one of it with one queue: commits line up, it
takes them in order, one at a time. A task is either something it can do from the machine (look up,
research, draft, call through Dial), which it does and reports in the note, or something only the
owner can do (go to the gym), where it asks whether it is done. A question parks that task and the
agent takes the next one; the answer, from the page, the app or a call, puts the task back in line,
and a yes closes it. It never restructures the board: no schedules, duplicates or due dates. The
owner does that. The queue survives a restart: runs left queued are taken up again.

## Status

Built and tested: the store, the migration, the demo set, the board and its direct actions, commit
runs that invoke a coding agent directly and end done or asking, answers that resume a run,
retransforms through the chat model, bounded retries and hand-back, the event log, the board at any
moment and restore, who-did-what, the voice agent's client tools with mechanical confirmation, the
signed URL, the post-call transcript, recall across the board and your coding conversations, the
Keewano forwarder (off without a key), calls out through Dial for committed tasks that name a phone
number, the internal board page, and the ElevenLabs agent sync from `elevenlabs/agent.json`. Twelve
integration tests, one diagram each, in `TESTING.md`.

The mobile app is built (`mobile-app/`, SwiftUI; the call screen runs on the ElevenLabs Swift SDK). Not built: Darwin, Alike as a memory source.

## A shared dev backend

`Dockerfile` at the root builds the backend into one image with the board page and pi as the agent
command (committed tasks run on OpenRouter's gemini-3.5-flash-lite inside the container). Railway
builds it as is: `railway init`, set the variables from `.env.example`, then `./deploy.sh` — a
direct upload of this working tree (no git hook) that waits for the new build to answer. Set `UNDERCURRENT_API_KEY` there: with it, every request but the health check and the page
needs `Authorization: Bearer <key>`, so only people with the key can reach the board.
`MOBILE_APP.md` has the exact steps.

## Integrations fail on their own

The board and the agent need no key. Every other integration is off without its key, and its
failures stay inside it: a Dial call that does not go through hands the task back with the reason,
a Keewano post that fails is logged and the event stays in the local table, a chat-model summary
that fails becomes a plain sentence. The agent runs in a scratch folder (`AGENT_DIR`), so nothing a
project carries — hooks, settings, files — is in its way or at its mercy.

## Calls

A committed task that says *call* (or phone, ring, dial) and names a phone number is a call, not a
coding job: the run places it through
[Dial](https://getdial.ai) with the task and its context as the voice agent's instruction, waits for
it to end, and closes the task with a summary. The transcript comes back as the next step, **Review
call notes: …**, unstaged with the transcript in its context. A busy, unanswered or failed call hands
the task back to staged with the reason in its note.

```sh
npm install -g @getdial/cli && dial auth login you@example.com    # then verify-otp, register-number, verify-otp --number
```

The last step saves the key (`~/.local/share/dial/auth.v1.json`) and provisions your first number;
put them in `.env` as `DIAL_API_KEY` and `DIAL_FROM_NUMBER`. Free accounts get five-minute calls,
two at a time. `go test ./...` never dials: `TestDialLiveCall` places one real call only with
`DIAL_LIVE_TEST=1` and `DIAL_LIVE_TO` set.

## The voice agent

```sh
go run ./cmd/undercurrent elevenlabs sync      # creates or updates the agent and its tools from elevenlabs/agent.json
```

Put the printed id in `.env` as `ELEVENLABS_AGENT_ID`, with `ELEVENLABS_API_KEY` and a
`LIVE_TOOL_SECRET` of your choosing. The tools are **client tools**: the board page (and later the
app) runs them against the local backend, so nothing needs a public URL or a tunnel. The page's
**Call** button starts the conversation on a signed URL and hands the agent the whole board as a
dynamic variable, so it knows every task from the first word and the owner can say where each one
should sit (`move_task`). When the call ends, the page posts the transcript back and the backend
keeps it as a live session with a one-line summary.
