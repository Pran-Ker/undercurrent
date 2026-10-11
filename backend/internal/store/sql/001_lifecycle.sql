-- The lifecycle: a task is unstaged, staged, committed or closed; a committed task has a run;
-- every action is an event. Applied by `undercurrent migrate`; safe to run twice.
ALTER TABLE task ADD COLUMN stage TEXT NOT NULL DEFAULT 'unstaged';
ALTER TABLE task ADD COLUMN context TEXT NOT NULL DEFAULT '';
ALTER TABLE task ADD COLUMN parent_id TEXT;
ALTER TABLE task ADD COLUMN created_by TEXT NOT NULL DEFAULT 'user';
ALTER TABLE task ADD COLUMN updated_at TEXT;

CREATE TABLE IF NOT EXISTS agent_run (
  id          TEXT PRIMARY KEY,
  task_id     TEXT NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('commit','retransform')),
  status      TEXT NOT NULL CHECK (status IN ('queued','running','needs_you','done','failed')),
  question    TEXT,
  answer      TEXT,
  steps       TEXT NOT NULL DEFAULT '[]',
  result      TEXT,
  cost_cents  INTEGER NOT NULL DEFAULT 0,
  started_at  TEXT,
  ended_at    TEXT
);
CREATE INDEX IF NOT EXISTS agent_run_task ON agent_run (task_id, status);

CREATE TABLE IF NOT EXISTS event (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  at       TEXT NOT NULL,
  actor    TEXT NOT NULL,
  action   TEXT NOT NULL,
  task_id  TEXT,
  run_id   TEXT,
  before   TEXT,
  after    TEXT,
  note     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS event_task ON event (task_id, at);
CREATE INDEX IF NOT EXISTS event_actor ON event (actor, at);

CREATE TABLE IF NOT EXISTS live_session (
  conversation_id TEXT PRIMARY KEY,
  started_at      TEXT,
  ended_at        TEXT,
  transcript      TEXT NOT NULL DEFAULT '[]',
  summary         TEXT NOT NULL DEFAULT ''
);

-- The demo set: garage lines are unstaged, open tray tasks are staged with their note as context,
-- finished rows are closed.
UPDATE task SET stage = 'closed' WHERE done IS NOT NULL AND stage = 'unstaged';
UPDATE task SET stage = 'staged', context = note WHERE layer = 'tray' AND done IS NULL AND stage = 'unstaged';
UPDATE task SET updated_at = entry WHERE updated_at IS NULL;
