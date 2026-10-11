package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/pran-ker/undercurrent/backend/internal/store"
)

// fakeDial is a scripted counterpart for Dial's REST API: it records the last placement and answers
// the status poll for a number with the outcome the script gives it — termination and transcript.
func fakeDial(t *testing.T, script map[string][2]string) (*httptest.Server, map[string]any) {
	t.Helper()
	placed := map[string]any{}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/calls", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-key" {
			w.WriteHeader(401)
			return
		}
		json.NewDecoder(r.Body).Decode(&placed)
		placed["idempotency"] = r.Header.Get("Idempotency-Key")
		json.NewEncoder(w).Encode(map[string]any{"call": map[string]any{"id": "call_" + placed["to"].(string), "to": placed["to"], "status": map[string]any{"state": "Queued"}}})
	})
	mux.HandleFunc("GET /api/v1/calls/{id}", func(w http.ResponseWriter, r *http.Request) {
		to := strings.TrimPrefix(r.PathValue("id"), "call_")
		s := script[to]
		json.NewEncoder(w).Encode(map[string]any{"call": map[string]any{"id": r.PathValue("id"), "to": to, "duration": 83,
			"status": map[string]any{"state": "Terminated", "terminationType": s[0], "label": s[0]}, "transcript": s[1]}})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, placed
}

// I11 · a committed task that names a phone number is a call: Dial places it with the task as the
// instruction, the transcript becomes the run's step, the task closes with a summary, and "Review
// call notes" appears as the next step with the transcript in its context. An unanswered call hands
// the task back with the reason.
func TestI11CommittedCallTaskDialsAndLeavesReviewNotes(t *testing.T) {
	dialSrv, placed := fakeDial(t, map[string][2]string{
		"+14155550123": {"completed", "assistant: Hi, I'm calling for Sam about a dentist appointment.\ncallee: We have Tuesday at 9.\nassistant: Tuesday at 9, booked. Thank you."},
		"+14155550199": {"no-answer", ""},
	})
	t.Setenv("DIAL_API_KEY", "test-key")
	t.Setenv("DIAL_BASE_URL", dialSrv.URL)
	t.Setenv("DIAL_FROM_NUMBER", "+15550001111")
	srv := flows(t, fakeAgent(t, "!fail"), chatSaying(`{"summary": "The clinic offered Tuesday at 9 and the appointment was booked."}`))

	task := staged(t, srv, "call the dentist at +14155550123 and book a morning slot", "Elm street clinic; any weekday morning; it is for Sam")
	var run store.Run
	if code := call(t, srv, "POST", "/tasks/"+task.ID+"/commit", "", &run); code != 202 {
		t.Fatalf("commit: %d", code)
	}
	instruction, _ := placed["outboundInstruction"].(string)
	if placed["to"] != "+14155550123" || placed["fromNumber"] != "+15550001111" || !strings.Contains(instruction, "book a morning slot") || !strings.Contains(instruction, "Elm street") || placed["idempotency"] != run.ID {
		t.Fatalf("placed = %v", placed)
	}
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	if run.Status != "done" || len(run.Steps) != 1 || run.Steps[0].Kind != "call" || run.Steps[0].Exit != 0 || !strings.Contains(run.Steps[0].Output, "Tuesday at 9") || !strings.Contains(run.Result, "booked") {
		t.Fatalf("run = %+v", run)
	}
	call(t, srv, "GET", "/tasks/"+task.ID, "", &task)
	if task.Stage != "closed" || !strings.Contains(task.Note, "booked") {
		t.Errorf("task = %+v", task)
	}
	var unstaged []store.Task
	call(t, srv, "GET", "/tasks?stage=unstaged", "", &unstaged)
	if len(unstaged) != 1 || unstaged[0].Text != "Review call notes: "+task.Text || unstaged[0].ParentID != task.ID || unstaged[0].CreatedBy != "agent" || !strings.Contains(unstaged[0].Context, "TRANSCRIPT") || !strings.Contains(unstaged[0].Context, "Tuesday at 9") {
		t.Errorf("review task = %+v", unstaged)
	}
	if got := strings.Join(actions(t, srv, task.ID), " "); got != "user:add user:stage user:commit agent:call agent:close" {
		t.Errorf("events = %s", got)
	}

	// unanswered: the task comes back staged with the reason, and no review task appears
	landlord := staged(t, srv, "call the landlord at +14155550199 about the deposit", "ask when it is coming back")
	call(t, srv, "POST", "/tasks/"+landlord.ID+"/commit", "", &run)
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	call(t, srv, "GET", "/tasks/"+landlord.ID, "", &landlord)
	if run.Status != "failed" || len(run.Steps) != 1 || run.Steps[0].Exit != 1 || landlord.Stage != "staged" || !strings.Contains(landlord.Note, "no-answer") {
		t.Errorf("unanswered: run = %+v task = %+v", run, landlord)
	}
	if got := strings.Join(actions(t, srv, landlord.ID), " "); got != "user:add user:stage user:commit agent:call agent:hand_back" {
		t.Errorf("events = %s", got)
	}
	call(t, srv, "GET", "/tasks?stage=unstaged", "", &unstaged)
	if len(unstaged) != 1 {
		t.Errorf("an unanswered call must not leave review notes; unstaged = %+v", unstaged)
	}
}

// TestDialLiveCall places one real call through Dial to DIAL_LIVE_TO and waits for it to end. It
// runs only with DIAL_LIVE_TEST=1 — calls are metered — and the number comes from the environment,
// never from the repo. Set OPENROUTER_API_KEY too for a model-written summary.
func TestDialLiveCall(t *testing.T) {
	if os.Getenv("DIAL_LIVE_TEST") != "1" {
		t.Skip("set DIAL_LIVE_TEST=1 with DIAL_API_KEY, DIAL_FROM_NUMBER and DIAL_LIVE_TO to place one real call")
	}
	to := os.Getenv("DIAL_LIVE_TO")
	if to == "" || os.Getenv("DIAL_API_KEY") == "" {
		t.Fatal("DIAL_LIVE_TO and DIAL_API_KEY are needed")
	}
	srv := flows(t, fakeAgent(t, "!fail"), nil)
	task := staged(t, srv, "call "+to+" and ask how the hackathon day is going",
		"this is the board's first real call: say you are the owner's assistant calling to check in, ask one question about how the day is going, thank them, and end the call within a minute")
	var run store.Run
	if code := call(t, srv, "POST", "/tasks/"+task.ID+"/commit", "", &run); code != 202 {
		t.Fatalf("commit: %d", code)
	}
	call(t, srv, "GET", "/runs/"+run.ID, "", &run)
	t.Logf("run %s: %s — %s", run.ID, run.Status, run.Result)
	for _, s := range run.Steps {
		t.Logf("step %s · %s · exit %d · %dms\n%s", s.Kind, s.Note, s.Exit, s.Ms, s.Output)
	}
	if run.Status != "done" {
		t.Fatalf("run = %+v", run)
	}
	var unstaged []store.Task
	call(t, srv, "GET", "/tasks?stage=unstaged", "", &unstaged)
	if len(unstaged) != 1 || !strings.HasPrefix(unstaged[0].Text, "Review call notes") {
		t.Fatalf("review task = %+v", unstaged)
	}
	t.Logf("review task:\n%s", unstaged[0].Context)
}
