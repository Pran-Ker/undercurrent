package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/pran-ker/undercurrent/backend/internal/store"
)

// commit hands a staged task to the agent.
func (a *API) commit(w http.ResponseWriter, r *http.Request) {
	t, ok, err := a.S.Task(r.PathValue("id"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	if !ok {
		fail(w, 404, "no such task")
		return
	}
	if t.Stage != "staged" {
		fail(w, 409, "only a staged task can be committed")
		return
	}
	run, err := a.Runner.Commit(t, actor(r))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	run, _, _ = a.S.Run(run.ID)
	writeJSON(w, 202, run)
}

func (a *API) retransform(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Instruction string `json:"instruction"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || strings.TrimSpace(b.Instruction) == "" {
		fail(w, 400, "instruction is required")
		return
	}
	t, ok, err := a.S.Task(r.PathValue("id"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	if !ok {
		fail(w, 404, "no such task")
		return
	}
	if t.Stage != "staged" {
		fail(w, 409, "only a staged task can be retransformed")
		return
	}
	run, say, err := a.Runner.Retransform(t, b.Instruction, actor(r))
	if err != nil {
		writeJSON(w, 502, map[string]any{"error": err.Error(), "run": run})
		return
	}
	run, _, _ = a.S.Run(run.ID)
	writeJSON(w, 200, map[string]any{"run": run, "say": say})
}

func (a *API) runs(w http.ResponseWriter, r *http.Request) {
	rs, err := a.S.Runs(r.URL.Query().Get("task"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, rs)
}

func (a *API) run(w http.ResponseWriter, r *http.Request) {
	run, ok, err := a.S.Run(r.PathValue("id"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	if !ok {
		fail(w, 404, "no such run")
		return
	}
	writeJSON(w, 200, run)
}

func (a *API) answer(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Answer string `json:"answer"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || strings.TrimSpace(b.Answer) == "" {
		fail(w, 400, "answer is required")
		return
	}
	run, ok, err := a.S.Run(r.PathValue("id"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	if !ok {
		fail(w, 404, "no such run")
		return
	}
	if run.Status != "needs_you" {
		fail(w, 409, "this run is not waiting for an answer")
		return
	}
	if _, err := a.Runner.Answer(run, strings.TrimSpace(b.Answer), actor(r)); err != nil {
		fail(w, 500, err.Error())
		return
	}
	run, _, _ = a.S.Run(run.ID)
	writeJSON(w, 202, run)
}

// state is the board as it was at a moment.
func (a *API) state(w http.ResponseWriter, r *http.Request) {
	at := r.URL.Query().Get("at")
	if at == "" {
		at = store.Now()
	}
	tasks, err := a.S.StateAt(at)
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"at": at, "tasks": tasks})
}

func (a *API) whoDidWhat(w http.ResponseWriter, r *http.Request) {
	since := r.URL.Query().Get("since")
	if since == "" {
		since = time.Now().UTC().Add(-24 * time.Hour).Format("2006-01-02T15:04:05Z")
	}
	out, err := a.S.WhoDidWhat(since)
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"since": since, "actors": out})
}

// restore brings the board back to a moment with compensating events; nothing is deleted. A task
// that did not exist then is closed with a note.
func (a *API) restore(w http.ResponseWriter, r *http.Request) {
	at := r.URL.Query().Get("at")
	if at == "" {
		fail(w, 400, "at is required")
		return
	}
	then, err := a.S.StateAt(at)
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	now, err := a.S.Tasks("")
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	was := map[string]store.Task{}
	for _, t := range then {
		was[t.ID] = t
	}
	who := actor(r)
	restored, closed := 0, 0
	for _, cur := range now {
		if cur.Stage == "committed" {
			continue // the agent's until its run ends
		}
		snap, existed := was[cur.ID]
		before := cur
		switch {
		case !existed:
			if cur.Stage == "closed" {
				continue
			}
			cur.Stage, cur.Done = "closed", store.Today()
			cur.Note = strings.TrimSpace(cur.Note + "\nrestore: did not exist at " + at)
			closed++
		case same(snap, cur):
			continue
		default:
			snap.ID = cur.ID
			cur = snap
			restored++
		}
		if err := a.S.Put(cur); err != nil {
			fail(w, 500, err.Error())
			return
		}
		after, _, _ := a.S.Task(cur.ID)
		a.S.Record(who, "restore", &before, &after, "to "+at)
	}
	writeJSON(w, 200, map[string]any{"at": at, "restored": restored, "closed": closed})
}

func same(a, b store.Task) bool {
	a.UpdatedAt, b.UpdatedAt = "", ""
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}
