package store

import (
	"database/sql"
	"encoding/json"
	"strings"
)

// Task is one row on the board. Stage is unstaged, staged, committed or closed.
type Task struct {
	ID        string   `json:"id"`
	Stage     string   `json:"stage"`
	Text      string   `json:"text"`
	Context   string   `json:"context"`
	Priority  string   `json:"priority,omitempty"`
	Due       string   `json:"due,omitempty"`
	Tags      []string `json:"tags"`
	Note      string   `json:"note"`
	ParentID  string   `json:"parent_id,omitempty"`
	CreatedBy string   `json:"created_by"`
	Entry     string   `json:"entry"`
	Done      string   `json:"done,omitempty"`
	UpdatedAt string   `json:"updated_at,omitempty"`
}

const taskCols = "id, stage, text, context, coalesce(priority,''), coalesce(due,''), tags, note, coalesce(parent_id,''), created_by, entry, coalesce(done,''), coalesce(updated_at,'')"

func scanTask(r interface{ Scan(...any) error }) (Task, error) {
	var t Task
	var tags string
	err := r.Scan(&t.ID, &t.Stage, &t.Text, &t.Context, &t.Priority, &t.Due, &tags, &t.Note, &t.ParentID, &t.CreatedBy, &t.Entry, &t.Done, &t.UpdatedAt)
	t.Tags = strings.Fields(tags)
	if t.Tags == nil {
		t.Tags = []string{}
	}
	return t, err
}

// Tasks lists the board, optionally one stage, in the order they were written down.
func (s *Store) Tasks(stage string) ([]Task, error) {
	q, args := "SELECT "+taskCols+" FROM task", []any{}
	if stage != "" {
		q, args = q+" WHERE stage = ?", []any{stage}
	}
	rows, err := s.DB.Query(q+" ORDER BY rowid", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Task{}
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Store) Task(id string) (Task, bool, error) {
	t, err := scanTask(s.DB.QueryRow("SELECT "+taskCols+" FROM task WHERE id = ?", id))
	if err == sql.ErrNoRows {
		return t, false, nil
	}
	return t, err == nil, err
}

// Add writes a task down. Every field it is not given stays empty; the id is minted here.
func (s *Store) Add(t Task) (Task, error) {
	t.ID, t.Entry, t.UpdatedAt = NewID(), Today(), Now()
	if t.Stage == "" {
		t.Stage = "unstaged"
	}
	if t.CreatedBy == "" {
		t.CreatedBy = "user"
	}
	if t.Tags == nil {
		t.Tags = []string{}
	}
	_, err := s.DB.Exec(`INSERT INTO task (id, layer, month, text, priority, due, entry, tags, note, stage, context, parent_id, created_by, updated_at)
		VALUES (?, 'garage', NULL, ?, nullif(?, ''), nullif(?, ''), ?, ?, ?, ?, ?, nullif(?, ''), ?, ?)`,
		t.ID, t.Text, t.Priority, t.Due, t.Entry, strings.Join(t.Tags, " "), t.Note, t.Stage, t.Context, t.ParentID, t.CreatedBy, t.UpdatedAt)
	return t, err
}

// Put writes a task back, whole.
func (s *Store) Put(t Task) error {
	t.UpdatedAt = Now()
	_, err := s.DB.Exec(`UPDATE task SET stage = ?, text = ?, context = ?, priority = nullif(?, ''), due = nullif(?, ''), tags = ?, note = ?,
		parent_id = nullif(?, ''), done = nullif(?, ''), updated_at = ? WHERE id = ?`,
		t.Stage, t.Text, t.Context, t.Priority, t.Due, strings.Join(t.Tags, " "), t.Note, t.ParentID, t.Done, t.UpdatedAt, t.ID)
	return err
}

// Event is one action, with the task as it was before and after.
type Event struct {
	ID     int64  `json:"id"`
	At     string `json:"at"`
	Actor  string `json:"actor"`
	Action string `json:"action"`
	TaskID string `json:"task_id,omitempty"`
	RunID  string `json:"run_id,omitempty"`
	Before *Task  `json:"before,omitempty"`
	After  *Task  `json:"after,omitempty"`
	Note   string `json:"note,omitempty"`
}

func (s *Store) Record(actor, action string, before, after *Task, note string) error {
	return s.RecordRun(actor, action, "", before, after, note)
}

func nullJSON(v *Task, b []byte) any {
	if v == nil {
		return nil
	}
	return string(b)
}

// Events lists the log, newest last; task, actor and since filter it.
func (s *Store) Events(taskID, actor, since string) ([]Event, error) {
	q, args := "SELECT id, at, actor, action, coalesce(task_id,''), coalesce(run_id,''), before, after, note FROM event WHERE 1=1", []any{}
	if taskID != "" {
		q, args = q+" AND task_id = ?", append(args, taskID)
	}
	if actor != "" {
		q, args = q+" AND actor = ?", append(args, actor)
	}
	if since != "" {
		q, args = q+" AND at >= ?", append(args, since)
	}
	rows, err := s.DB.Query(q+" ORDER BY id", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		var e Event
		var before, after sql.NullString
		if err := rows.Scan(&e.ID, &e.At, &e.Actor, &e.Action, &e.TaskID, &e.RunID, &before, &after, &e.Note); err != nil {
			return nil, err
		}
		if before.Valid {
			var t Task
			if json.Unmarshal([]byte(before.String), &t) == nil {
				e.Before = &t
			}
		}
		if after.Valid {
			var t Task
			if json.Unmarshal([]byte(after.String), &t) == nil {
				e.After = &t
			}
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
