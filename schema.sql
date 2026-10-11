-- The task table. One row per task, on one of two layers:
--   garage  anything written down, with no structure yet; month says when you'll look at it
--   tray    the few tasks picked on purpose, each with a priority, maybe a due date, and tags
-- Ids are four random base36 characters, permanent. Dates are YYYY-MM-DD. Tags are space-separated.
CREATE TABLE IF NOT EXISTS task (
  id         TEXT PRIMARY KEY,
  layer      TEXT NOT NULL CHECK (layer IN ('tray','garage')),
  month      TEXT,                                   -- garage only: YYYY-MM, or 'someday'
  text       TEXT NOT NULL,
  priority   TEXT CHECK (priority IN ('H','M','L')),
  due        TEXT,
  wait       TEXT,                                   -- the day a garage line surfaces on the tray
  recur      TEXT,                                   -- a template: a period in words (daily · weekly · monthly · yearly · 3d · 2w) or a cron expression (0 7 * * 1-5)
  until      TEXT,                                   -- a template's last day
  entry      TEXT NOT NULL,                          -- the day it was written down
  done       TEXT,                                   -- the day it was finished; NULL while open
  from_month TEXT,                                   -- the garage month a tray task was taken from
  tags       TEXT NOT NULL DEFAULT '',
  note       TEXT NOT NULL DEFAULT '',
  source     TEXT                                    -- where it came from, as origin:key — recur:<template id> for a template's child; call:, text:, email:, calendar: for the outside
);
CREATE INDEX IF NOT EXISTS task_layer ON task (layer, month, done);
CREATE INDEX IF NOT EXISTS task_source ON task (source);
