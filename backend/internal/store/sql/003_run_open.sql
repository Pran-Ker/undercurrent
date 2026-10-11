-- A run can end open: the secretary asked, the owner has not done it yet. SQLite cannot drop a
-- check, so agent_run is rebuilt once; Migrate records each applied file in meta and skips it after.
CREATE TABLE agent_run_new (
  id          TEXT PRIMARY KEY,
  task_id     TEXT NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('commit','retransform')),
  status      TEXT NOT NULL CHECK (status IN ('queued','running','needs_you','open','done','failed')),
  question    TEXT,
  answer      TEXT,
  steps       TEXT NOT NULL DEFAULT '[]',
  result      TEXT,
  cost_cents  INTEGER NOT NULL DEFAULT 0,
  started_at  TEXT,
  ended_at    TEXT
);
INSERT INTO agent_run_new SELECT id, task_id, kind, status, question, answer, steps, result, cost_cents, started_at, ended_at FROM agent_run;
DROP TABLE agent_run;
ALTER TABLE agent_run_new RENAME TO agent_run;
CREATE INDEX IF NOT EXISTS agent_run_task ON agent_run (task_id, status);
