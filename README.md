# undercurrent

A personal agent you reach by text or by phone call. It keeps your tasks and acts on them: writes
down what you say, picks a few things up on purpose, and calls or messages you when something is
due.

## Status

Day zero. What exists:

- `schema.sql` — the task table: two layers, a garage for anything written down and a tray for the
  few things picked on purpose. Permanent four-character ids, dates as days, tags as words.
- A Turso database named `undercurrent` holding that table and a demo set of tasks. Its URL and
  token live in `.env` (gitignored), as `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN`.

Everything else — the agent, the call surface, the text surface — is still to be designed.
