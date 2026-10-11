package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pran-ker/undercurrent/backend/internal/store"
)

func scratch(t *testing.T) *httptest.Server {
	t.Helper()
	s, err := store.OpenFile("file:" + filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Migrate(); err != nil {
		t.Fatal(err)
	}
	demo, err := os.ReadFile("../../db/demo.sql")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Seed(string(demo)); err != nil {
		t.Fatal(err)
	}
	if err := s.Migrate(); err != nil { // the demo rows take their stages from the migration's backfill
		t.Fatal(err)
	}
	srv := httptest.NewServer((&API{S: s}).Routes())
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, method, path, body string, out any) int {
	t.Helper()
	req, _ := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

// The demo set lands in its stages: garage lines unstaged, open tray tasks staged with their note
// as context, finished rows closed.
func TestTheDemoSetTakesItsStages(t *testing.T) {
	srv := scratch(t)
	var all []store.Task
	call(t, srv, "GET", "/tasks", "", &all)
	n := map[string]int{}
	for _, x := range all {
		n[x.Stage]++
	}
	if len(all) != 42 || n["unstaged"] != 22 || n["staged"] != 16 || n["closed"] != 4 || n["committed"] != 0 {
		t.Fatalf("stages = %v of %d", n, len(all))
	}
}

// I4 · direct add, stage, edit, close — no agent, four events by `user`.
func TestDirectActionsLeaveEvents(t *testing.T) {
	srv := scratch(t)
	var task store.Task
	if code := call(t, srv, "POST", "/tasks", `{"text":"book the dentist","tags":["health"]}`, &task); code != 201 || task.Stage != "unstaged" {
		t.Fatalf("add: %d %+v", code, task)
	}
	if code := call(t, srv, "POST", "/tasks/"+task.ID+"/stage", `{"context":"mornings only, the one on Elm street"}`, &task); code != 200 || task.Stage != "staged" {
		t.Fatalf("stage: %d %+v", code, task)
	}
	if code := call(t, srv, "PATCH", "/tasks/"+task.ID, `{"text":"book the dentist for a cleaning"}`, &task); code != 200 || task.Text != "book the dentist for a cleaning" || task.Context == "" {
		t.Fatalf("edit: %d %+v", code, task)
	}
	if code := call(t, srv, "POST", "/tasks/"+task.ID+"/close", "", &task); code != 200 || task.Stage != "closed" || task.Done == "" {
		t.Fatalf("close: %d %+v", code, task)
	}
	if code := call(t, srv, "POST", "/tasks/"+task.ID+"/close", "", nil); code != 409 {
		t.Errorf("closing twice should refuse, got %d", code)
	}
	var evs []store.Event
	call(t, srv, "GET", "/events?task="+task.ID, "", &evs)
	var actions []string
	for _, e := range evs {
		actions = append(actions, e.Actor+":"+e.Action)
	}
	if strings.Join(actions, " ") != "user:add user:stage user:edit user:close" {
		t.Errorf("events = %v", actions)
	}
	if evs[1].Before.Stage != "unstaged" || evs[1].After.Stage != "staged" {
		t.Errorf("the stage event should carry before and after: %+v", evs[1])
	}
}

// What is not built says so, rather than pretending.
func TestUnbuiltEndpointsSaySo(t *testing.T) {
	srv := scratch(t)
	var body map[string]string
	if code := call(t, srv, "POST", "/tasks/x/commit", "", &body); code != 501 || body["error"] != "not built yet" {
		t.Errorf("commit: %d %v", code, body)
	}
}
