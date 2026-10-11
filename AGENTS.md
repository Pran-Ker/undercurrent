# Working on undercurrent

Instructions for any coding agent in this repository.

## What this is

A voice-first personal agent for the things you have to do. Tasks sit on a board — `unstaged`,
`staged`, `committed`, `closed` — and every move is an event. `README.md` is the overview,
`backend/API.md` the contract, `MOBILE_APP.md` the app, `TESTING.md` the tests, `SUGGESTIONS.md`
the research. Read `README.md` and `backend/API.md` before changing anything.

## Rules

- **Nothing is faked.** What is not built returns 501 with `{"error": "not built yet"}`; a test uses
  a scripted or simulated counterpart that behaves like the real thing on the wire, never a stub
  that pretends the work happened.
- **Every write leaves an event** with `actor`, `action`, `before` and `after`. Go through
  `store.Record`; never update the task table without it.
- **Key actions on a call are confirmed in code**, not in a prompt: commit, close, edit, split and
  complete answer with a read-back until called again with `confirmed: true`.
- **One integration test per flow, with a diagram** in `TESTING.md`. Smaller tests get a line.
- **No erase.** A closed task is closed.
- **Keep the repo generic.** No personal data, tokens, phone numbers or machine paths in tracked
  files; secrets live in `.env`, which is gitignored.
- **Hack project.** Prefer the simplest thing that works over anything built for scale: no job
  queues, no workflow engines, one binary.

## Run

```sh
cp .env.example .env
cd backend
go run ./cmd/undercurrent seed    # migrate + the 42-task demo set into a local file
go run ./cmd/undercurrent serve   # http://127.0.0.1:8787 — the board at /, the API at /tasks
go test ./...
```

Set `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` in `.env` to work on the shared board.

## Layout

`backend/cmd/undercurrent` the binary · `backend/internal/store` the database and migrations ·
`backend/internal/api` the HTTP surface · `backend/internal/dial` calls out through Dial (off without a key; failures stay inside the run) · `backend/internal-web-ui` the internal board page ·
`backend/db` schema, migrations and the demo set · `mobile-app` the Expo app.

## Before you finish

`cd backend && gofmt -l . && go vet ./... && go test ./...` — all three clean. Update
`backend/API.md` when an endpoint changes, and `TESTING.md` when a test is added.
