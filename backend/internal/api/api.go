// Package api is the HTTP surface. Every write names its actor and leaves an event.
package api

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/pran-ker/undercurrent/backend/internal/live"
	"github.com/pran-ker/undercurrent/backend/internal/oracle"
	"github.com/pran-ker/undercurrent/backend/internal/runs"
	"github.com/pran-ker/undercurrent/backend/internal/store"
)

type API struct {
	S      *store.Store
	Runner *runs.Runner
	Live   *live.Live
	UI     string // the folder the board page is served from
}

// New wires the API from the environment: the agent command, the chat model, the live secrets,
// the transcripts folder the oracle reads.
func New(s *store.Store) *API {
	recall := func(q string) string { return oracle.Recall(s, q, os.Getenv("ORACLE_TRANSCRIPTS"), 6) }
	r := runs.New(s)
	r.Recall = recall
	return &API{S: s, Runner: r, Live: live.New(s, r, recall), UI: "internal-web-ui"}
}

func (a *API) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", a.health)
	mux.HandleFunc("GET /tasks", a.list)
	mux.HandleFunc("POST /tasks", a.add)
	mux.HandleFunc("GET /tasks/{id}", a.get)
	mux.HandleFunc("PATCH /tasks/{id}", a.edit)
	mux.HandleFunc("POST /tasks/{id}/stage", a.stage)
	mux.HandleFunc("POST /tasks/{id}/close", a.close)
	mux.HandleFunc("POST /tasks/{id}/commit", a.commit)
	mux.HandleFunc("POST /tasks/{id}/retransform", a.retransform)
	mux.HandleFunc("GET /runs", a.runs)
	mux.HandleFunc("GET /runs/{id}", a.run)
	mux.HandleFunc("POST /runs/{id}/answer", a.answer)
	mux.HandleFunc("GET /events", a.events)
	mux.HandleFunc("GET /state", a.state)
	mux.HandleFunc("GET /who-did-what", a.whoDidWhat)
	mux.HandleFunc("POST /restore", a.restore)
	mux.HandleFunc("POST /live/tools/{name}", a.Live.Tool)
	mux.HandleFunc("GET /live/config", a.Live.Config)
	mux.HandleFunc("GET /live/signed-url", a.Live.SignedURL)
	mux.HandleFunc("POST /live/post-call", a.Live.PostCall)
	mux.Handle("GET /", http.FileServer(http.Dir(a.UI)))
	return cors(auth(os.Getenv("UNDERCURRENT_API_KEY"), mux))
}

// auth makes the backend fit for a public URL: with UNDERCURRENT_API_KEY set, every request but the
// health check and the page itself must carry the key, as `Authorization: Bearer <key>` or
// `X-Api-Key`. Without the key set, nothing changes, the backend is local.
func auth(key string, h http.Handler) http.Handler {
	if key == "" {
		return h
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" || r.URL.Path == "/" || r.URL.Path == "/index.html" {
			h.ServeHTTP(w, r)
			return
		}
		given := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if given == "" {
			given = r.Header.Get("X-Api-Key")
		}
		if subtle.ConstantTimeCompare([]byte(given), []byte(key)) != 1 {
			fail(w, 401, "this backend needs its key: Authorization: Bearer <UNDERCURRENT_API_KEY>")
			return
		}
		h.ServeHTTP(w, r)
	})
}

func cors(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Actor, Authorization, X-Api-Key, X-Live-Secret")
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// actor is who did it: `user` unless the caller says otherwise (a run says agent:<id>, the live
// agent says live:<conversation id>).
func actor(r *http.Request) string {
	if a := r.Header.Get("X-Actor"); a != "" {
		return a
	}
	return "user"
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	var n int
	if err := a.S.DB.QueryRow("SELECT count(*) FROM task").Scan(&n); err != nil {
		fail(w, 500, err.Error())
		return
	}
	out := map[string]any{"ok": true, "tasks": n}
	if id := os.Getenv("RAILWAY_DEPLOYMENT_ID"); id != "" {
		out["deployment"] = id // which build is answering; deploy.sh waits for the one it just sent
	}
	writeJSON(w, 200, out)
}

func (a *API) list(w http.ResponseWriter, r *http.Request) {
	stage := r.URL.Query().Get("stage")
	if stage != "" && !validStage(stage) {
		fail(w, 400, "stage is unstaged, staged, committed or closed")
		return
	}
	tasks, err := a.S.Tasks(stage)
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, tasks)
}

func validStage(s string) bool {
	return s == "unstaged" || s == "staged" || s == "committed" || s == "closed"
}

func (a *API) get(w http.ResponseWriter, r *http.Request) {
	t, ok, err := a.S.Task(r.PathValue("id"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	if !ok {
		fail(w, 404, "no such task")
		return
	}
	writeJSON(w, 200, t)
}

type addBody struct {
	Text     string   `json:"text"`
	Context  string   `json:"context"`
	Tags     []string `json:"tags"`
	Priority string   `json:"priority"`
	Due      string   `json:"due"`
	Stage    string   `json:"stage"`
	ParentID string   `json:"parent_id"`
}

// add writes a task down: unstaged by default; staged if context is given with stage=staged.
func (a *API) add(w http.ResponseWriter, r *http.Request) {
	var b addBody
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || strings.TrimSpace(b.Text) == "" {
		fail(w, 400, "text is required")
		return
	}
	stage := "unstaged"
	if b.Stage == "staged" && b.Context != "" {
		stage = "staged"
	}
	who := actor(r)
	t, err := a.S.Add(store.Task{Text: strings.TrimSpace(b.Text), Context: b.Context, Tags: b.Tags, Priority: b.Priority, Due: b.Due, Stage: stage, ParentID: b.ParentID, CreatedBy: kind(who)})
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	a.S.Record(who, "add", nil, &t, "")
	writeJSON(w, 201, t)
}

func kind(actor string) string {
	switch {
	case strings.HasPrefix(actor, "agent:"):
		return "agent"
	case strings.HasPrefix(actor, "live:"):
		return "live"
	}
	return "user"
}

// stage attaches the context that makes a task ready for an agent.
func (a *API) stage(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Context string `json:"context"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || strings.TrimSpace(b.Context) == "" {
		fail(w, 400, "context is required")
		return
	}
	a.transition(w, r, "stage", func(t *store.Task) string {
		if t.Stage != "unstaged" && t.Stage != "staged" {
			return "only an unstaged or staged task can be staged"
		}
		t.Stage, t.Context = "staged", strings.TrimSpace(b.Context)
		return ""
	})
}

// edit changes the words, the context or the tags, on any open task, with no agent involved.
func (a *API) edit(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Text    *string   `json:"text"`
		Context *string   `json:"context"`
		Tags    *[]string `json:"tags"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
		fail(w, 400, "bad json")
		return
	}
	a.transition(w, r, "edit", func(t *store.Task) string {
		if t.Stage == "closed" {
			return "a closed task is closed"
		}
		if b.Text != nil && strings.TrimSpace(*b.Text) != "" {
			t.Text = strings.TrimSpace(*b.Text)
		}
		if b.Context != nil {
			t.Context = *b.Context
		}
		if b.Tags != nil {
			t.Tags = *b.Tags
		}
		return ""
	})
}

func (a *API) close(w http.ResponseWriter, r *http.Request) {
	a.transition(w, r, "close", func(t *store.Task) string {
		if t.Stage == "closed" {
			return "already closed"
		}
		if t.Stage == "committed" {
			return "a committed task is the agent's until its run ends"
		}
		t.Stage, t.Done = "closed", store.Today()
		return ""
	})
}

// transition applies one change to one task and records it: before, after, who.
func (a *API) transition(w http.ResponseWriter, r *http.Request, action string, change func(*store.Task) string) {
	t, ok, err := a.S.Task(r.PathValue("id"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	if !ok {
		fail(w, 404, "no such task")
		return
	}
	before := t
	if msg := change(&t); msg != "" {
		fail(w, 409, msg)
		return
	}
	if err := a.S.Put(t); err != nil {
		fail(w, 500, err.Error())
		return
	}
	after, _, _ := a.S.Task(t.ID)
	a.S.Record(actor(r), action, &before, &after, "")
	writeJSON(w, 200, after)
}

func (a *API) events(w http.ResponseWriter, r *http.Request) {
	evs, err := a.S.Events(r.URL.Query().Get("task"), r.URL.Query().Get("actor"), r.URL.Query().Get("since"))
	if err != nil {
		fail(w, 500, err.Error())
		return
	}
	if n, _ := strconv.Atoi(r.URL.Query().Get("limit")); n > 0 && len(evs) > n {
		evs = evs[len(evs)-n:] // the most recent n, oldest first
	}
	writeJSON(w, 200, evs)
}
