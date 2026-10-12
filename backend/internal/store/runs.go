package store

import (
	"database/sql"
	"encoding/json"
	"strings"
)

// A Run is one agent at work on one task: a commit, or a retransform.
type Run struct {
	ID        string `json:"id"`
	TaskID    string `json:"task_id"`
	Kind      string `json:"kind"`
	Status    string `json:"status"`
	Question  string `json:"question,omitempty"`
	Answer    string `json:"answer,omitempty"`
	Steps     []Step `json:"steps"`
	Result    string `json:"result,omitempty"`
	CostCents int    `json:"cost_cents"`
	StartedAt string `json:"started_at,omitempty"`
	EndedAt   string `json:"ended_at,omitempty"`
}

// A Step is one thing the run did: an agent invocation, a retry, an answer, an applied operation.
type Step struct {
	At     string `json:"at"`
	Kind   string `json:"kind"`
	Cmd    string `json:"cmd,omitempty"`
	Exit   int    `json:"exit"`
	Ms     int64  `json:"ms"`
	Output string `json:"output,omitempty"`
	Note   string `json:"note,omitempty"`
}

const runCols = "id, task_id, kind, status, coalesce(question,''), coalesce(answer,''), steps, coalesce(result,''), cost_cents, coalesce(started_at,''), coalesce(ended_at,'')"

func scanRun(r interface{ Scan(...any) error }) (Run, error) {
	var x Run
	var steps string
	err := r.Scan(&x.ID, &x.TaskID, &x.Kind, &x.Status, &x.Question, &x.Answer, &steps, &x.Result, &x.CostCents, &x.StartedAt, &x.EndedAt)
	json.Unmarshal([]byte(steps), &x.Steps)
	if x.Steps == nil {
		x.Steps = []Step{}
	}
	return x, err
}

func (s *Store) NewRun(taskID, kind string) (Run, error) {
	r := Run{ID: NewID(), TaskID: taskID, Kind: kind, Status: "queued", Steps: []Step{}, StartedAt: Now()}
	_, err := s.DB.Exec(`INSERT INTO agent_run (id, task_id, kind, status, steps, started_at) VALUES (?, ?, ?, 'queued', '[]', ?)`, r.ID, taskID, kind, r.StartedAt)
	return r, err
}

func (s *Store) Run(id string) (Run, bool, error) {
	r, err := scanRun(s.DB.QueryRow("SELECT "+runCols+" FROM agent_run WHERE id = ?", id))
	if err == sql.ErrNoRows {
		return r, false, nil
	}
	return r, err == nil, err
}

// Runs lists runs, newest first; a task id narrows them.
func (s *Store) Runs(taskID string) ([]Run, error) {
	q, args := "SELECT "+runCols+" FROM agent_run", []any{}
	if taskID != "" {
		q, args = q+" WHERE task_id = ?", []any{taskID}
	}
	rows, err := s.DB.Query(q+" ORDER BY rowid DESC", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Run{}
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) PutRun(r Run) error {
	steps, _ := json.Marshal(r.Steps)
	_, err := s.DB.Exec(`UPDATE agent_run SET status = ?, question = nullif(?, ''), answer = nullif(?, ''), steps = ?, result = nullif(?, ''), cost_cents = ?, ended_at = nullif(?, '') WHERE id = ?`,
		r.Status, r.Question, r.Answer, string(steps), r.Result, r.CostCents, r.EndedAt, r.ID)
	return err
}

// A Session is one live conversation, kept from the post-call webhook.
type Session struct {
	ConversationID string           `json:"conversation_id"`
	StartedAt      string           `json:"started_at,omitempty"`
	EndedAt        string           `json:"ended_at,omitempty"`
	Transcript     []map[string]any `json:"transcript"`
	Summary        string           `json:"summary"`
}

func (s *Store) PutSession(x Session) error {
	t, _ := json.Marshal(x.Transcript)
	_, err := s.DB.Exec(`INSERT OR REPLACE INTO live_session (conversation_id, started_at, ended_at, transcript, summary) VALUES (?, nullif(?, ''), nullif(?, ''), ?, ?)`,
		x.ConversationID, x.StartedAt, x.EndedAt, string(t), x.Summary)
	return err
}

func (s *Store) Sessions() ([]Session, error) {
	rows, err := s.DB.Query("SELECT conversation_id, coalesce(started_at,''), coalesce(ended_at,''), transcript, summary FROM live_session ORDER BY rowid DESC")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Session{}
	for rows.Next() {
		var x Session
		var t string
		if err := rows.Scan(&x.ConversationID, &x.StartedAt, &x.EndedAt, &t, &x.Summary); err != nil {
			return nil, err
		}
		json.Unmarshal([]byte(t), &x.Transcript)
		out = append(out, x)
	}
	return out, rows.Err()
}

func (s *Store) Meta(key string) string {
	var v string
	s.DB.QueryRow("SELECT value FROM meta WHERE key = ?", key).Scan(&v)
	return v
}

func (s *Store) SetMeta(key, value string) error {
	_, err := s.DB.Exec("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", key, value)
	return err
}

// RecordRun is Record with the run that did it.
func (s *Store) RecordRun(actor, action, runID string, before, after *Task, note string) error {
	var taskID string
	if after != nil {
		taskID = after.ID
	} else if before != nil {
		taskID = before.ID
	}
	b, _ := json.Marshal(before)
	a, _ := json.Marshal(after)
	e := Event{At: Now(), Actor: actor, Action: action, TaskID: taskID, RunID: runID, Before: before, After: after, Note: note}
	_, err := s.DB.Exec(`INSERT INTO event (at, actor, action, task_id, run_id, before, after, note) VALUES (?, ?, ?, ?, nullif(?, ''), ?, ?, ?)`,
		e.At, actor, action, taskID, runID, nullJSON(before, b), nullJSON(after, a), note)
	if err == nil && s.OnEvent != nil {
		s.OnEvent(e)
	}
	return err
}

// SeedEvents gives every task that has no event one `seeded` event, so time travel has a floor.
func (s *Store) SeedEvents() (int, error) {
	tasks, err := s.Tasks("")
	if err != nil {
		return 0, err
	}
	n := 0
	for _, t := range tasks {
		var c int
		s.DB.QueryRow("SELECT count(*) FROM event WHERE task_id = ?", t.ID).Scan(&c)
		if c == 0 {
			t := t
			if err := s.RecordRun("system", "seeded", "", nil, &t, "the demo set"); err != nil {
				return n, err
			}
			n++
		}
	}
	return n, nil
}

// StateAt is the board as it was: for each task, the `after` of its last event at or before `at`.
func (s *Store) StateAt(at string) ([]Task, error) {
	rows, err := s.DB.Query("SELECT task_id, after FROM event WHERE at <= ? AND after IS NOT NULL ORDER BY id", at)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	latest := map[string]Task{}
	var order []string
	for rows.Next() {
		var id, after string
		if err := rows.Scan(&id, &after); err != nil {
			return nil, err
		}
		var t Task
		if json.Unmarshal([]byte(after), &t) != nil {
			continue
		}
		if _, seen := latest[id]; !seen {
			order = append(order, id)
		}
		latest[id] = t
	}
	out := []Task{}
	for _, id := range order {
		out = append(out, latest[id])
	}
	return out, rows.Err()
}

// Actor is one line of who-did-what.
type Actor struct {
	Actor   string         `json:"actor"`
	Actions map[string]int `json:"actions"`
	Tasks   int            `json:"tasks"`
	LastAt  string         `json:"last_at"`
}

func (s *Store) WhoDidWhat(since string) ([]Actor, error) {
	rows, err := s.DB.Query("SELECT actor, action, coalesce(task_id,''), at FROM event WHERE at >= ? ORDER BY id", since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	by := map[string]*Actor{}
	tasks := map[string]map[string]bool{}
	var order []string
	for rows.Next() {
		var actor, action, task, at string
		if err := rows.Scan(&actor, &action, &task, &at); err != nil {
			return nil, err
		}
		a := by[actor]
		if a == nil {
			a = &Actor{Actor: actor, Actions: map[string]int{}}
			by[actor], tasks[actor] = a, map[string]bool{}
			order = append(order, actor)
		}
		a.Actions[action]++
		a.LastAt = at
		if task != "" {
			tasks[actor][task] = true
		}
	}
	out := []Actor{}
	for _, k := range order {
		by[k].Tasks = len(tasks[k])
		out = append(out, *by[k])
	}
	return out, rows.Err()
}

// Resolve turns an id, or enough of a task's words, into the one open task it names, or the
// candidates when it is unclear. A voice agent that has not listed will guess an id from words.
func (s *Store) Resolve(ref string) (Task, []Task, error) {
	ref = strings.ToLower(strings.TrimSpace(ref))
	all, err := s.Tasks("")
	if err != nil {
		return Task{}, nil, err
	}
	for _, t := range all {
		if t.ID == ref {
			return t, nil, nil
		}
	}
	var hits []Task
	for _, t := range all {
		if t.Stage != "closed" && ref != "" && strings.Contains(strings.ToLower(t.Text), ref) {
			hits = append(hits, t)
		}
	}
	if len(hits) != 1 {
		words := strings.Fields(ref)
		hits = nil
		for _, t := range all {
			if t.Stage == "closed" || len(words) == 0 {
				continue
			}
			ok := true
			for _, w := range words {
				if !strings.Contains(strings.ToLower(t.Text), w) {
					ok = false
				}
			}
			if ok {
				hits = append(hits, t)
			}
		}
	}
	if len(hits) == 1 {
		return hits[0], nil, nil
	}
	return Task{}, hits, nil
}
