# undercurrent

A personal agent you reach by text or by phone call. It keeps your tasks and acts on them: writes
down what you say, picks a few things up on purpose, and calls or messages you when something is
due.

## Status

Day zero. What exists:

- `schema.sql` — the task table: two layers, a garage for anything written down and a tray for the
  few things picked on purpose. Permanent four-character ids, dates as days, tags as words.
- `demo.sql` — a demo set of 42 tasks covering every shape the table allows: recurring templates
  with a period in words or a cron expression, the children they produce, lines waiting for their
  day, tasks captured from a call, a text, an email or a calendar event, an overdue one, a
  handed-back one, finished ones, and a someday pile. The demo's today is 2026-09-01.
- A Turso database named `undercurrent` holding that table and that demo set. Its URL and token
  live in `.env` (gitignored), as `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN`. An empty database
  is rebuilt with `turso db shell <db> < schema.sql && turso db shell <db> < demo.sql`.

Everything else — the agent, the call surface, the text surface — is still to be designed.
