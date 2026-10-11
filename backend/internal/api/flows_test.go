package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pran-ker/undercurrent/backend/internal/live"
	"github.com/pran-ker/undercurrent/backend/internal/store"
)

// fakeAgent is a scripted counterpart for the agent command: it reads the prompt on stdin and
// prints the lines of a script file, one invocation each (a `!fail` line exits 1).
func fakeAgent(t *testing.T, lines ...string) string {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "script")
	os.WriteFile(script, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
	bin := filepath.Join(dir, "agent.sh")
	os.WriteFile(bin, []byte(`#!/bin/sh
cat > "$0.last-prompt"
n=$(cat "$0.n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$0.n"
line=$(sed -n "${n}p" "`+script+`")
case "$line" in "!fail") echo "boom" >&2; exit 1 ;; esac
printf '%s\n' "$line"
`), 0o755)
	return bin
}

func verdict(outcome, note, question, next string) string {
	b, _ := json.Marshal(map[string]string{"outcome": outcome, "note": note, "question": question, "next": next})
	return "some reasoning first, then the verdict: UNDERCURRENT: " + string(b)
}

func flows(t *testing.T, agent string, chat http.HandlerFunc) *httptest.Server {
	t.Helper()
	t.Setenv("AGENT_CMD", agent)
	if os.Getenv("UNDERCURRENT_SYNC_RUNS") == "" {
		t.Setenv("UNDERCURRENT_SYNC_RUNS", "1") // I12 sets 0 first to use the real queue
	}
	t.Setenv("LIVE_TOOL_SECRET", "s3cret")
	t.Setenv("ELEVENLABS_WEBHOOK_SECRET", "wh-secret")
	if chat != nil {
		model := httptest.NewServer(chat)
		t.Cleanup(model.Close)
		t.Setenv("OPENROUTER_BASE_URL", model.URL)
		t.Setenv("OPENROUTER_API_KEY", "test")
	}
	s, err := store.OpenFile("file:" + filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Migrate(); err != nil {
		t.Fatal(err)
	}
	a := New(s)
	a.Runner.Backoff = 10 * time.Millisecond
	srv := httptest.NewServer(a.Routes())
	t.Cleanup(srv.Close)
	return srv
}

func chatSaying(ops string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"choices": []map[string]any{{"message": map[string]string{"content": ops}}}})
	}
}

func staged(t *testing.T, srv *httptest.Server, text, context string) store.Task {
	t.Helper()
	var task store.Task
	call(t, srv, "POST", "/tasks", fmt.Sprintf(`{"text":%q}`, text), &task)
	call(t, srv, "POST", "/tasks/"+task.ID+"/stage", fmt.Sprintf(`{"context":%q}`, context), &task)
	return task
}

func actions(t *testing.T, srv *httptest.Server, taskID string) []string {
	t.Helper()
	var evs []store.Event
	call(t, srv, "GET", "/events?task="+taskID, "", &evs)
	var out []string
	for _, e := range evs {
		actor := e.Actor
		if strings.HasPrefix(actor, "agent:") {
			actor = "agent"
		}
		out = append(out, actor+":"+e.Action)
	}
	return out
}

// I1 · stage → commit → the agent finishes → the task closes with a note and the next step appears unstaged.
func TestI1CommitRunsTheAgentAndYieldsTheNextStep(t *testing.T) {
	srv := flows(t, fakeAgent(t, verdict("done", "Called the clinic, booked Tuesday 9am.", "", "Put the appointment in the calendar")), nil)
	task := staged(t, srv, "book the dentist", "mornings only, Elm street")
	var run store.Run
	if code := call(t, srv, "POST", "/tasks/"+task.ID+"/commit", "", &run); code != 202 {
		t.Fatalf("commit: %d", code)
	}
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	if run.Status != "done" || !strings.Contains(run.Result, "Tuesday") || len(run.Steps) != 1 || run.Steps[0].Kind != "agent" {
		t.Fatalf("run = %+v", run)
	}
	call(t, srv, "GET", "/tasks/"+task.ID, "", &task)
	if task.Stage != "closed" || !strings.Contains(task.Note, "Tuesday") {
		t.Errorf("task = %+v", task)
	}
	var unstaged []store.Task
	call(t, srv, "GET", "/tasks?stage=unstaged", "", &unstaged)
	if len(unstaged) != 1 || unstaged[0].Text != "Put the appointment in the calendar" || unstaged[0].ParentID != task.ID || unstaged[0].CreatedBy != "agent" {
		t.Errorf("next step = %+v", unstaged)
	}
	if got := strings.Join(actions(t, srv, task.ID), " "); got != "user:add user:stage user:commit agent:close" {
		t.Errorf("events = %s", got)
	}
	prompt, _ := os.ReadFile(os.Getenv("AGENT_CMD") + ".last-prompt")
	if !strings.Contains(string(prompt), "mornings only, Elm street") || !strings.Contains(string(prompt), "UNDERCURRENT:") {
		t.Errorf("the prompt should carry the context and the verdict contract:\n%s", prompt)
	}
}

// I2 · retransform: "half done, the rest is X" → the task closes, a staged next appears.
func TestI2RetransformCompletesAndYieldsTheNext(t *testing.T) {
	srv := flows(t, fakeAgent(t), chatSaying(`{"ops":[{"op":"complete","note":"the forms are filled","next":{"text":"post the forms","context":"the post office on Main, before 5"}}],"say":"Marked the forms done; posting them is next."}`))
	task := staged(t, srv, "fill and post the forms", "tax forms")
	var out struct {
		Run store.Run `json:"run"`
		Say string    `json:"say"`
	}
	if code := call(t, srv, "POST", "/tasks/"+task.ID+"/retransform", `{"instruction":"the forms are filled, now they need posting at the Main street post office before 5"}`, &out); code != 200 {
		t.Fatalf("retransform: %d %+v", code, out)
	}
	if out.Run.Status != "done" || !strings.Contains(out.Say, "next") {
		t.Errorf("run = %+v say = %q", out.Run, out.Say)
	}
	call(t, srv, "GET", "/tasks/"+task.ID, "", &task)
	var st []store.Task
	call(t, srv, "GET", "/tasks?stage=staged", "", &st)
	if task.Stage != "closed" || len(st) != 1 || st[0].Text != "post the forms" || st[0].Context != "the post office on Main, before 5" || st[0].ParentID != task.ID {
		t.Errorf("task = %+v staged = %+v", task, st)
	}
}

// I3 · retransform: split into three → three staged children, the parent closed.
func TestI3RetransformSplitsIntoChildren(t *testing.T) {
	srv := flows(t, fakeAgent(t), chatSaying(`{"ops":[{"op":"split","children":[{"text":"pack the kitchen","context":"boxes in the garage"},{"text":"pack the books"},{"text":"book the van","context":"Saturday"}]}],"say":"Split into three."}`))
	task := staged(t, srv, "pack for the move", "moving on the 20th")
	call(t, srv, "POST", "/tasks/"+task.ID+"/retransform", `{"instruction":"split this into kitchen, books and the van"}`, nil)
	var st []store.Task
	call(t, srv, "GET", "/tasks?stage=staged", "", &st)
	call(t, srv, "GET", "/tasks/"+task.ID, "", &task)
	if len(st) != 3 || task.Stage != "closed" || !strings.Contains(task.Note, "split into 3") {
		t.Fatalf("staged = %d task = %+v", len(st), task)
	}
	for _, c := range st {
		if c.ParentID != task.ID || c.CreatedBy != "agent" {
			t.Errorf("child = %+v", c)
		}
	}
	if n := strings.Count(strings.Join(actions(t, srv, task.ID), " "), "agent:"); n != 1 {
		t.Errorf("the parent should carry one agent event (close), got %d", n)
	}
}

// I5 · live: add and commit by voice — the first commit call returns the read-back, the second lands.
func TestI5LiveToolsReadBackThenLand(t *testing.T) {
	srv := flows(t, fakeAgent(t, verdict("done", "done", "", "")), nil)
	tool := func(name, body string) map[string]any {
		req, _ := http.NewRequest("POST", srv.URL+"/live/tools/"+name, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Live-Secret", "s3cret")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		json.NewDecoder(resp.Body).Decode(&out)
		return out
	}
	if out := tool("add_task", `{"text":"book the dentist","context":"Elm street, mornings","conversation_id":"conv1"}`); out["ok"] != true || !strings.Contains(out["result"].(string), "staged") {
		t.Fatalf("add: %v", out)
	}
	first := tool("commit_task", `{"ref":"dentist","conversation_id":"conv1"}`)
	if first["needs_confirmation"] != true || !strings.Contains(first["read_back"].(string), "Commit") || !strings.Contains(first["read_back"].(string), "book the dentist") {
		t.Fatalf("first call should read back: %v", first)
	}
	var st []store.Task
	call(t, srv, "GET", "/tasks?stage=staged", "", &st)
	if len(st) != 1 {
		t.Fatal("nothing lands before the word")
	}
	second := tool("commit_task", `{"ref":"dentist","confirmed":true,"conversation_id":"conv1"}`)
	if second["ok"] != true {
		t.Fatalf("second call should land: %v", second)
	}
	if got := strings.Join(actions(t, srv, st[0].ID), " "); got != "live:conv1:add live:conv1:commit agent:close" {
		t.Errorf("events = %s", got)
	}
	if out := tool("move_task", `{"ref":"`+st[0].ID+`","stage":"unstaged","conversation_id":"conv1"}`); out["ok"] != true || !strings.Contains(out["result"].(string), "now unstaged") {
		t.Fatalf("move: %v", out)
	}
	var cfg map[string]any
	call(t, srv, "GET", "/live/config", "", &cfg)
	if b, _ := cfg["board"].(string); !strings.Contains(b, "[unstaged] book the dentist") {
		t.Errorf("the config should carry the board for the agent: %v", cfg["board"])
	}
	req, _ := http.NewRequest("POST", srv.URL+"/live/tools/list_board", strings.NewReader("{}"))
	req.Header.Set("X-Live-Secret", "wrong")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 403 {
		t.Errorf("a bad secret should be refused, got %d", resp.StatusCode)
	}
}

// I6 · the agent asks → the owner answers → the run resumes with the answer → done.
func TestI6AnAgentQuestionIsAnsweredAndTheRunResumes(t *testing.T) {
	srv := flows(t, fakeAgent(t, verdict("needs_you", "", "Which card should pay, the blue or the business one?", ""), verdict("done", "Paid with the business card.", "", "")), nil)
	task := staged(t, srv, "pay the electricity bill", "84.20, autopay failed")
	var run store.Run
	call(t, srv, "POST", "/tasks/"+task.ID+"/commit", "", &run)
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	if run.Status != "needs_you" || !strings.Contains(run.Question, "Which card") {
		t.Fatalf("run = %+v", run)
	}
	call(t, srv, "GET", "/tasks/"+task.ID, "", &task)
	if task.Stage != "committed" {
		t.Errorf("a waiting task stays committed, got %s", task.Stage)
	}
	if code := call(t, srv, "POST", "/runs/"+run.ID+"/answer", `{"answer":"the business one"}`, &run); code != 202 {
		t.Fatalf("answer: %d", code)
	}
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	if run.Status != "done" || run.Answer != "the business one" || len(run.Steps) != 3 || run.Steps[1].Kind != "answer" {
		t.Errorf("run = %+v", run)
	}
	prompt, _ := os.ReadFile(os.Getenv("AGENT_CMD") + ".last-prompt")
	if !strings.Contains(string(prompt), "THE OWNER ANSWERED: the business one") {
		t.Errorf("the second prompt should carry the answer")
	}
	call(t, srv, "GET", "/tasks/"+task.ID, "", &task)
	if task.Stage != "closed" {
		t.Errorf("task = %+v", task)
	}
}

// I12 · one agent, one queue: two commits are taken in order; the first asks and parks its task,
// the second is done meanwhile; the open question travels with the board to the voice agent; the
// answer puts the first back in line and it closes.
func TestI12OneAgentWorksTheQueueAndAQuestionParksTheTask(t *testing.T) {
	t.Setenv("UNDERCURRENT_SYNC_RUNS", "0")
	srv := flows(t, fakeAgent(t, verdict("needs_you", "", "Did you go to the gym?", ""), verdict("done", "Looked it up: sunny, 61°F.", "", ""), verdict("done", "The owner went this morning.", "", "")), nil)
	gym := staged(t, srv, "go to the gym", "weekday mornings")
	weather := staged(t, srv, "what is the weather today", "San Francisco")
	var r1, r2 store.Run
	call(t, srv, "POST", "/tasks/"+gym.ID+"/commit", "", &r1)
	call(t, srv, "POST", "/tasks/"+weather.ID+"/commit", "", &r2)
	settle := func(id, want string) store.Run {
		deadline := time.Now().Add(5 * time.Second)
		for {
			var run store.Run
			call(t, srv, "GET", "/runs/"+id, "", &run)
			if run.Status == want {
				return run
			}
			if time.Now().After(deadline) {
				t.Fatalf("run %s is %s, wanted %s", id, run.Status, want)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	settle(r1.ID, "needs_you") // the agent script is consumed in order: the gym got the question line, the weather the done line
	settle(r2.ID, "done")
	call(t, srv, "GET", "/tasks/"+gym.ID, "", &gym)
	call(t, srv, "GET", "/tasks/"+weather.ID, "", &weather)
	if gym.Stage != "committed" || weather.Stage != "closed" {
		t.Fatalf("gym = %s weather = %s", gym.Stage, weather.Stage)
	}
	var cfg map[string]any
	call(t, srv, "GET", "/live/config", "", &cfg)
	if b, _ := cfg["board"].(string); !strings.Contains(b, "Did you go to the gym?") {
		t.Errorf("the board handed to the voice agent should carry the open question:\n%s", b)
	}
	call(t, srv, "POST", "/runs/"+r1.ID+"/answer", `{"answer":"yes, this morning"}`, &r1)
	settle(r1.ID, "done")
	call(t, srv, "GET", "/tasks/"+gym.ID, "", &gym)
	if gym.Stage != "closed" || !strings.Contains(gym.Note, "went") {
		t.Errorf("gym = %+v", gym)
	}
}

// The secretary asked "did you go?", the owner said not yet: the task stays open on the board.
func TestOpenVerdictKeepsTheTaskStaged(t *testing.T) {
	srv := flows(t, fakeAgent(t, verdict("open", "The owner has not gone yet; they plan to tomorrow.", "", "")), nil)
	task := staged(t, srv, "go to the gym", "weekday mornings")
	var run store.Run
	call(t, srv, "POST", "/tasks/"+task.ID+"/commit", "", &run)
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	call(t, srv, "GET", "/tasks/"+task.ID, "", &task)
	if run.Status != "open" || task.Stage != "staged" || task.Note != "The owner has not gone yet; they plan to tomorrow." {
		t.Errorf("run = %+v task = %+v", run, task)
	}
	if got := strings.Join(actions(t, srv, task.ID), " "); got != "user:add user:stage user:commit agent:hand_back" {
		t.Errorf("events = %s", got)
	}
}

// I7 · time travel: a handful of actions, three moments, the board as it was at each.
func TestI7StateAtAMoment(t *testing.T) {
	srv := flows(t, fakeAgent(t), nil)
	var a, b store.Task
	call(t, srv, "POST", "/tasks", `{"text":"first"}`, &a)
	time.Sleep(1100 * time.Millisecond)
	var evs []store.Event
	call(t, srv, "GET", "/events", "", &evs)
	t1 := evs[len(evs)-1].At
	call(t, srv, "POST", "/tasks", `{"text":"second"}`, &b)
	call(t, srv, "POST", "/tasks/"+a.ID+"/stage", `{"context":"ctx"}`, nil)
	time.Sleep(1100 * time.Millisecond)
	call(t, srv, "GET", "/events", "", &evs)
	t2 := evs[len(evs)-1].At
	call(t, srv, "POST", "/tasks/"+a.ID+"/close", "", nil)
	var s1, s2, s3 struct{ Tasks []store.Task }
	call(t, srv, "GET", "/state?at="+t1, "", &s1)
	call(t, srv, "GET", "/state?at="+t2, "", &s2)
	call(t, srv, "GET", "/state", "", &s3)
	if len(s1.Tasks) != 1 || s1.Tasks[0].Stage != "unstaged" {
		t.Errorf("at t1: %+v", s1.Tasks)
	}
	if len(s2.Tasks) != 2 || s2.Tasks[0].Stage != "staged" || s2.Tasks[1].Text != "second" {
		t.Errorf("at t2: %+v", s2.Tasks)
	}
	if len(s3.Tasks) != 2 || s3.Tasks[0].Stage != "closed" {
		t.Errorf("now: %+v", s3.Tasks)
	}
	var res map[string]any
	call(t, srv, "POST", "/restore?at="+t1, "", &res)
	call(t, srv, "GET", "/tasks/"+a.ID, "", &a)
	call(t, srv, "GET", "/tasks/"+b.ID, "", &b)
	if a.Stage != "unstaged" || a.Context != "" || b.Stage != "closed" || res["restored"].(float64) != 1 || res["closed"].(float64) != 1 {
		t.Errorf("restore: a=%+v b=%+v res=%v", a, b, res)
	}
	if !strings.Contains(strings.Join(actions(t, srv, a.ID), " "), "user:restore") {
		t.Error("restore should be an event, never a deletion")
	}
}

// I8 · who-did-what over a mixed day.
func TestI8WhoDidWhat(t *testing.T) {
	srv := flows(t, fakeAgent(t, verdict("done", "ok", "", "")), nil)
	task := staged(t, srv, "a thing", "ctx")
	call(t, srv, "POST", "/tasks/"+task.ID+"/commit", "", nil)
	var other store.Task
	req, _ := http.NewRequest("POST", srv.URL+"/tasks", strings.NewReader(`{"text":"from the call"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Actor", "live:conv9")
	http.DefaultClient.Do(req)
	_ = other
	var w struct{ Actors []store.Actor }
	call(t, srv, "GET", "/who-did-what", "", &w)
	by := map[string]store.Actor{}
	for _, a := range w.Actors {
		if strings.HasPrefix(a.Actor, "agent:") {
			a.Actor = "agent"
		}
		by[a.Actor] = a
	}
	if by["user"].Actions["add"] != 1 || by["user"].Actions["stage"] != 1 || by["user"].Actions["commit"] != 1 || by["agent"].Actions["close"] != 1 || by["live:conv9"].Actions["add"] != 1 {
		t.Errorf("actors = %+v", w.Actors)
	}
}

// I9 · failure injection: the agent fails twice then succeeds → bounded retries carry it; a run
// that fails every time hands the task back.
func TestI9BoundedRetriesThenHandBack(t *testing.T) {
	srv := flows(t, fakeAgent(t, "!fail", "!fail", verdict("done", "third time lucky", "", ""), "!fail", "!fail", "!fail", "!fail"), nil)
	task := staged(t, srv, "flaky thing", "ctx")
	var run store.Run
	call(t, srv, "POST", "/tasks/"+task.ID+"/commit", "", &run)
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	kinds := []string{}
	for _, s := range run.Steps {
		kinds = append(kinds, fmt.Sprintf("%s:%d", s.Kind, s.Exit))
	}
	if run.Status != "done" || strings.Join(kinds, " ") != "agent:1 retry:1 retry:0" {
		t.Fatalf("run = %s steps = %v", run.Status, kinds)
	}
	second := staged(t, srv, "doomed thing", "ctx")
	call(t, srv, "POST", "/tasks/"+second.ID+"/commit", "", &run)
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	call(t, srv, "GET", "/tasks/"+second.ID, "", &second)
	if run.Status != "failed" || len(run.Steps) != 4 || second.Stage != "staged" || !strings.Contains(second.Note, "run failed") {
		t.Errorf("run = %+v task = %+v", run, second)
	}
	if got := strings.Join(actions(t, srv, second.ID), " "); got != "user:add user:stage user:commit agent:hand_back" {
		t.Errorf("events = %s", got)
	}
}

// I10 · the post-call webhook, signed, becomes a live session the oracle recalls.
func TestI10PostCallWebhookFeedsRecall(t *testing.T) {
	srv := flows(t, fakeAgent(t), nil)
	body := []byte(`{"type":"post_call_transcription","event_timestamp":1,"data":{"conversation_id":"conv42","transcript":[{"role":"user","message":"remind me the landlord prefers mornings"},{"role":"agent","message":"Noted."}],"metadata":{"start_time_unix_secs":1700000000,"call_duration_secs":61},"analysis":{"transcript_summary":"The owner said the landlord prefers mornings for the inspection."}}}`)
	post := func(sig string) int {
		req, _ := http.NewRequest("POST", srv.URL+"/live/post-call", strings.NewReader(string(body)))
		req.Header.Set("ElevenLabs-Signature", sig)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := post("t=1,v0=deadbeef"); code != 401 {
		t.Fatalf("a bad signature should be refused, got %d", code)
	}
	if code := post(live.Sign(body, "wh-secret", time.Now())); code != 200 {
		t.Fatalf("a good signature should land, got %d", code)
	}
	req, _ := http.NewRequest("POST", srv.URL+"/live/tools/recall", strings.NewReader(`{"query":"landlord mornings"}`))
	req.Header.Set("X-Live-Secret", "s3cret")
	resp, _ := http.DefaultClient.Do(req)
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	if !strings.Contains(fmt.Sprint(out["result"]), "conv42") || !strings.Contains(fmt.Sprint(out["result"]), "prefers mornings") {
		t.Errorf("recall = %v", out)
	}
	var evs []store.Event
	call(t, srv, "GET", "/events?actor=live:conv42", "", &evs)
	if len(evs) != 1 || evs[0].Action != "call" {
		t.Errorf("a call should be one event by its conversation: %+v", evs)
	}
}
