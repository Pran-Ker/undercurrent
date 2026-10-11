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
moment and restore, who-did-what, the voice agent's client tools with mechanical confirmation, the
signed URL, the post-call transcript, recall across the board and your coding conversations, the
Keewano forwarder (off without a key), calls out through Dial for committed tasks that name a phone
number, the internal board page, and the ElevenLabs agent sync from `elevenlabs/agent.json`. Eleven
integration tests, one diagram each, in `TESTING.md`.

Not built: the mobile app (spec in `MOBILE_APP.md`), Darwin, Alike as a memory source.

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
**Call** button starts the conversation on a signed URL; when it ends, the page posts the transcript
back and the backend keeps it as a live session with a one-line summary.
