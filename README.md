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
mobile-app/         Expo. See MOBILE_APP.md for what it is; README.md for how to start.
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
same board.

## Lifecycle

`unstaged` (written down) → `staged` (context added) → `committed` (an agent is on it) → `closed`.
A staged task can be retransformed — rewritten, enriched, split, or completed with the next step
yielded. Closing and editing never need an agent. There is no erase.

## Status

Built and tested: the store, the migration, the demo set, the board and its direct actions, commit
runs that invoke a coding agent directly and end done or asking, answers that resume a run,
retransforms through the chat model, bounded retries and hand-back, the event log, the board at any
moment and restore, who-did-what, the live agent's webhook tools with mechanical confirmation, the
signed URL, the post-call webhook, recall across the board and your coding conversations, the
Keewano forwarder (off without a key), the internal board page, and the ElevenLabs agent sync from
`elevenlabs/agent.json`. Ten integration tests, one diagram each, in `TESTING.md`.

Not built: the mobile app (spec in `MOBILE_APP.md`), phone calls out (Dial), Darwin, Alike as a
memory source.

## The live agent

```sh
cloudflared tunnel --url http://127.0.0.1:8787     # or any tunnel; put its https URL in PUBLIC_URL
go run ./cmd/undercurrent elevenlabs sync          # creates the tools and the agent; prints ELEVENLABS_AGENT_ID
```

Then set the post-call webhook in the ElevenLabs dashboard to `PUBLIC_URL/live/post-call` and its
secret in `ELEVENLABS_WEBHOOK_SECRET`. The board page's **Call** button opens the widget on a
signed URL.
