// Package live is the voice surface's side of the backend: the tools an ElevenLabs agent calls
// through the page or the app, the signed URL that starts a private conversation, and the
// post-call transcript that keeps the conversation as a session.
package live

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/pran-ker/undercurrent/backend/internal/runs"
	"github.com/pran-ker/undercurrent/backend/internal/store"
)

type Live struct {
	S             *store.Store
	Runner        *runs.Runner
	Secret        string // LIVE_TOOL_SECRET: the header every tool call must carry
	APIKey        string // ELEVENLABS_API_KEY
	AgentID       string // ELEVENLABS_AGENT_ID
	WebhookSecret string // ELEVENLABS_WEBHOOK_SECRET: the post-call signature
	Recall        func(string) string
}

func New(s *store.Store, r *runs.Runner, recall func(string) string) *Live {
	agent := os.Getenv("ELEVENLABS_AGENT_ID")
	if agent == "" {
		agent = s.Meta("elevenlabs_agent_id") // what `elevenlabs sync` minted
	}
	return &Live{S: s, Runner: r, Secret: os.Getenv("LIVE_TOOL_SECRET"), APIKey: os.Getenv("ELEVENLABS_API_KEY"),
		AgentID: agent, WebhookSecret: os.Getenv("ELEVENLABS_WEBHOOK_SECRET"), Recall: recall}
}

// Tools is the catalogue: name, class, what it does. The agent's configuration is generated
// from it (elevenlabs/agent.json names the same tools).
var Tools = []string{"list_board", "add_task", "stage_task", "move_task", "commit_task", "retransform", "edit_task", "close_task", "answer_agent", "recall"}

// Key tools need the owner's word: the first call returns the read-back, the second lands.
var Key = map[string]bool{"commit_task": true, "retransform": true, "edit_task": true, "close_task": true}

type args struct {
	Ref            string   `json:"ref"`
	Text           string   `json:"text"`
	Context        string   `json:"context"`
	Tags           []string `json:"tags"`
	Instruction    string   `json:"instruction"`
	Answer         string   `json:"answer"`
	Query          string   `json:"query"`
	Stage          string   `json:"stage"`
	Confirmed      bool     `json:"confirmed"`
	ConversationID string   `json:"conversation_id"`
}

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// Tool handles POST /live/tools/{name}.
func (l *Live) Tool(w http.ResponseWriter, r *http.Request) {
	if l.Secret == "" {
		reply(w, 503, map[string]string{"error": "LIVE_TOOL_SECRET is not set"})
		return
	}
	if r.Header.Get("X-Live-Secret") != l.Secret {
		reply(w, 403, map[string]string{"error": "bad secret"})
		return
	}
	name := r.PathValue("name")
	var a args
	json.NewDecoder(r.Body).Decode(&a)
	actor := "live"
	if a.ConversationID != "" {
		actor = "live:" + a.ConversationID
	}
	out, err := l.call(name, a, actor)
	if err != nil {
		reply(w, 200, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	reply(w, 200, out)
}

func (l *Live) call(name string, a args, actor string) (map[string]any, error) {
	ok := func(result string) map[string]any { return map[string]any{"ok": true, "result": result} }
	switch name {
	case "list_board":
		text, err := l.boardText(a.Stage)
		if err != nil {
			return nil, err
		}
		return ok(text), nil
	case "recall":
		if l.Recall == nil {
			return ok("(nothing to recall)"), nil
		}
		res := l.Recall(a.Query)
		if res == "" {
			res = "(nothing matched)"
		}
		return ok(res), nil
	case "add_task":
		if strings.TrimSpace(a.Text) == "" {
			return nil, fmt.Errorf("text is required")
		}
		t := store.Task{Text: strings.TrimSpace(a.Text), Tags: a.Tags, Context: a.Context, CreatedBy: "live"}
		if a.Context != "" {
			t.Stage = "staged"
		}
		t, err := l.S.Add(t)
		if err != nil {
			return nil, err
		}
		l.S.Record(actor, "add", nil, &t, "")
		return ok(fmt.Sprintf("added %s “%s” to the %s", t.ID, t.Text, t.Stage)), nil
	case "answer_agent":
		run, err := l.openQuestion(a.Ref)
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(a.Answer) == "" {
			return nil, fmt.Errorf("answer is required")
		}
		if _, err := l.Runner.Answer(run, a.Answer, actor); err != nil {
			return nil, err
		}
		return ok("answered; the agent is back on it"), nil
	}
	// everything below names a task
	t, candidates, err := l.S.Resolve(a.Ref)
	if err != nil {
		return nil, err
	}
	if t.ID == "" {
		if len(candidates) == 0 {
			return nil, fmt.Errorf("no task matches “%s”, list the board, or ask which", a.Ref)
		}
		return nil, fmt.Errorf("more than one task matches; ask which:\n%s", board(candidates))
	}
	if Key[name] && !a.Confirmed {
		return map[string]any{"ok": false, "needs_confirmation": true, "read_back": readBack(name, t, a)}, nil
	}
	switch name {
	case "move_task":
		if a.Stage != "unstaged" && a.Stage != "staged" {
			return nil, fmt.Errorf("stage must be unstaged or staged; close_task closes, commit_task commits")
		}
		if t.Stage == "committed" {
			return nil, fmt.Errorf("%s is with the agent; answer it or wait", t.ID)
		}
		before := t
		t.Stage, t.Done = a.Stage, ""
		l.S.Put(t)
		after, _, _ := l.S.Task(t.ID)
		l.S.Record(actor, "move", &before, &after, "")
		return ok(fmt.Sprintf("%s “%s” is now %s", t.ID, t.Text, t.Stage)), nil
	case "stage_task":
		if strings.TrimSpace(a.Context) == "" {
			return nil, fmt.Errorf("context is required to stage")
		}
		if t.Stage != "unstaged" && t.Stage != "staged" {
			return nil, fmt.Errorf("%s is %s; only an unstaged or staged task can be staged", t.ID, t.Stage)
		}
		before := t
		t.Stage, t.Context = "staged", strings.TrimSpace(a.Context)
		l.S.Put(t)
		after, _, _ := l.S.Task(t.ID)
		l.S.Record(actor, "stage", &before, &after, "")
		return ok(fmt.Sprintf("staged %s “%s”", t.ID, t.Text)), nil
	case "commit_task":
		if t.Stage != "staged" {
			return nil, fmt.Errorf("%s is %s; stage it first", t.ID, t.Stage)
		}
		run, err := l.Runner.Commit(t, actor)
		if err != nil {
			return nil, err
		}
		return ok(fmt.Sprintf("committed %s “%s”; run %s is on it", t.ID, t.Text, run.ID)), nil
	case "retransform":
		if strings.TrimSpace(a.Instruction) == "" {
			return nil, fmt.Errorf("instruction is required")
		}
		if t.Stage != "staged" {
			return nil, fmt.Errorf("%s is %s; only a staged task can be retransformed", t.ID, t.Stage)
		}
		_, say, err := l.Runner.Retransform(t, a.Instruction, actor)
		if err != nil {
			return nil, err
		}
		return ok(say), nil
	case "edit_task":
		if t.Stage == "closed" {
			return nil, fmt.Errorf("%s is closed", t.ID)
		}
		before := t
		if strings.TrimSpace(a.Text) != "" {
			t.Text = strings.TrimSpace(a.Text)
		}
		if a.Context != "" {
			t.Context = a.Context
		}
		if a.Tags != nil {
			t.Tags = a.Tags
		}
		l.S.Put(t)
		after, _, _ := l.S.Task(t.ID)
		l.S.Record(actor, "edit", &before, &after, "")
		return ok(fmt.Sprintf("changed %s “%s”", t.ID, t.Text)), nil
	case "close_task":
		if t.Stage == "closed" {
			return nil, fmt.Errorf("%s is already closed", t.ID)
		}
		if t.Stage == "committed" {
			return nil, fmt.Errorf("%s is committed; the agent's until its run ends", t.ID)
		}
		before := t
		t.Stage, t.Done = "closed", store.Today()
		l.S.Put(t)
		after, _, _ := l.S.Task(t.ID)
		l.S.Record(actor, "close", &before, &after, "")
		return ok(fmt.Sprintf("closed %s “%s”", t.ID, t.Text)), nil
	}
	return nil, fmt.Errorf("no tool named %s", name)
}

func (l *Live) openQuestion(ref string) (store.Run, error) {
	rs, err := l.S.Runs("")
	if err != nil {
		return store.Run{}, err
	}
	for _, r := range rs {
		if r.Status == "needs_you" && (ref == "" || r.ID == ref || r.TaskID == ref) {
			return r, nil
		}
	}
	return store.Run{}, fmt.Errorf("no run is waiting for an answer")
}

func readBack(name string, t store.Task, a args) string {
	who := fmt.Sprintf("%s “%s”", t.ID, t.Text)
	switch name {
	case "commit_task":
		return "Commit " + who + " to the agent?"
	case "close_task":
		return "Close " + who + "?"
	case "edit_task":
		if strings.TrimSpace(a.Text) != "" {
			return fmt.Sprintf("Change %s to “%s”?", who, strings.TrimSpace(a.Text))
		}
		return "Change the context of " + who + "?"
	case "retransform":
		return fmt.Sprintf("Retransform %s: “%s”?", who, a.Instruction)
	}
	return name + " " + who + "?"
}

func board(tasks []store.Task) string {
	if len(tasks) == 0 {
		return "(nothing)"
	}
	var lines []string
	for _, t := range tasks {
		line := fmt.Sprintf("%s [%s] %s", t.ID, t.Stage, t.Text)
		if t.Context != "" {
			line += ", " + t.Context
		}
		if len(t.Tags) > 0 {
			line += " +" + strings.Join(t.Tags, " +")
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

// Config handles GET /live/config: what the board page or the app needs to run a call, the agent
// id, the tool secret, and the board as text to hand the agent as a dynamic variable, so it knows
// every task from the first word. The backend is local; this is not an endpoint to expose.
func (l *Live) Config(w http.ResponseWriter, r *http.Request) {
	text, _ := l.boardText("")
	reply(w, 200, map[string]any{"agent_id": l.AgentID, "secret": l.Secret, "configured": l.APIKey != "" && l.AgentID != "" && l.Secret != "", "tools": Tools, "board": text})
}

// boardText is the board as the voice agent reads it, with the questions the agent is waiting on
// at the end, so a call can ask them and bring the answers back with answer_agent.
func (l *Live) boardText(stage string) (string, error) {
	tasks, err := l.S.Tasks(stage)
	if err != nil {
		return "", err
	}
	out := board(tasks)
	runs, _ := l.S.Runs("")
	var qs []string
	for _, r := range runs {
		if r.Status == "needs_you" {
			if t, ok, _ := l.S.Task(r.TaskID); ok {
				qs = append(qs, fmt.Sprintf("%s “%s”, the agent asks: %s", t.ID, t.Text, r.Question))
			}
		}
	}
	if len(qs) > 0 {
		out += "\n\nWAITING FOR THE PERSON'S ANSWER (ask, then answer_agent):\n" + strings.Join(qs, "\n")
	}
	return out, nil
}

// SignedURL handles GET /live/signed-url: the app and the page start a private conversation.
// The signed URL is the WebSocket (text, the page); the token is the WebRTC room the Swift SDK
// joins for voice. Either is empty when its upstream call failed; both failing is a 502.
func (l *Live) SignedURL(w http.ResponseWriter, r *http.Request) {
	if l.APIKey == "" || l.AgentID == "" {
		reply(w, 503, map[string]string{"error": "ELEVENLABS_API_KEY and ELEVENLABS_AGENT_ID are not set"})
		return
	}
	signed, err1 := l.elevenlabs("/v1/convai/conversation/get-signed-url", "signed_url")
	token, err2 := l.elevenlabs("/v1/convai/conversation/token", "token")
	if err1 != nil && err2 != nil {
		reply(w, 502, map[string]string{"error": "elevenlabs: " + err1.Error() + "; " + err2.Error()})
		return
	}
	reply(w, 200, map[string]string{"signed_url": signed, "token": token, "agent_id": l.AgentID})
}

// elevenlabs makes one GET for this agent and returns the named string field of the reply.
func (l *Live) elevenlabs(path, field string) (string, error) {
	req, _ := http.NewRequest("GET", "https://api.elevenlabs.io"+path+"?agent_id="+l.AgentID, nil)
	req.Header.Set("xi-api-key", l.APIKey)
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	if json.Unmarshal(raw, &out) != nil {
		return "", fmt.Errorf("%s: %s", path, strings.TrimSpace(string(raw)))
	}
	v, _ := out[field].(string)
	if v == "" {
		return "", fmt.Errorf("%s: %s", path, strings.TrimSpace(string(raw)))
	}
	return v, nil
}

// PostCall handles the post-call webhook: verified, the transcript becomes a live session.
func (l *Live) PostCall(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	if l.WebhookSecret != "" && !Verify(r.Header.Get("ElevenLabs-Signature"), raw, l.WebhookSecret, time.Now()) {
		reply(w, 401, map[string]string{"error": "bad signature"})
		return
	}
	var p struct {
		Type string `json:"type"`
		Data struct {
			ConversationID string           `json:"conversation_id"`
			Transcript     []map[string]any `json:"transcript"`
			Metadata       struct {
				Start    int64 `json:"start_time_unix_secs"`
				Duration int64 `json:"call_duration_secs"`
			} `json:"metadata"`
			Analysis struct {
				Summary string `json:"transcript_summary"`
			} `json:"analysis"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		reply(w, 400, map[string]string{"error": "bad json"})
		return
	}
	if p.Type != "post_call_transcription" {
		reply(w, 200, map[string]string{"ok": "ignored " + p.Type})
		return
	}
	x := store.Session{ConversationID: p.Data.ConversationID, Transcript: p.Data.Transcript, Summary: p.Data.Analysis.Summary}
	if x.Summary == "" && len(x.Transcript) > 0 && l.Runner != nil && l.Runner.Chat != nil {
		x.Summary = l.summarize(x.Transcript)
	}
	if p.Data.Metadata.Start > 0 {
		x.StartedAt = time.Unix(p.Data.Metadata.Start, 0).UTC().Format("2006-01-02T15:04:05Z")
		x.EndedAt = time.Unix(p.Data.Metadata.Start+p.Data.Metadata.Duration, 0).UTC().Format("2006-01-02T15:04:05Z")
	}
	if x.Transcript == nil {
		x.Transcript = []map[string]any{}
	}
	if err := l.S.PutSession(x); err != nil {
		reply(w, 500, map[string]string{"error": err.Error()})
		return
	}
	l.S.Record("live:"+x.ConversationID, "call", nil, nil, x.Summary)
	reply(w, 200, map[string]string{"ok": "stored"})
}

// Verify checks `t=<unix>,v0=<hex hmac-sha256 of "<t>.<body>">` within 30 minutes.
func Verify(header string, body []byte, secret string, now time.Time) bool {
	var ts, sig string
	for _, part := range strings.Split(header, ",") {
		k, v, _ := strings.Cut(strings.TrimSpace(part), "=")
		switch k {
		case "t":
			ts = v
		case "v0":
			sig = v
		}
	}
	if ts == "" || sig == "" {
		return false
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || now.Unix()-sec > 30*60 {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(ts + "."))
	mac.Write(body)
	return hmac.Equal([]byte(hex.EncodeToString(mac.Sum(nil))), []byte(sig))
}

// Sign makes a header the way ElevenLabs does, for tests and for a local simulator.
func Sign(body []byte, secret string, now time.Time) string {
	ts := strconv.FormatInt(now.Unix(), 10)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(ts + "."))
	mac.Write(body)
	return "t=" + ts + ",v0=" + hex.EncodeToString(mac.Sum(nil))
}

// summarize asks the chat model for one plain sentence about a call the page recorded itself;
// the platform's own webhook brings a summary along, the page cannot.
func (l *Live) summarize(turns []map[string]any) string {
	var lines []string
	for _, t := range turns {
		role, _ := t["role"].(string)
		msg, _ := t["message"].(string)
		if msg != "" {
			lines = append(lines, role+": "+msg)
		}
	}
	out, err := l.Runner.Chat("Summarize this call between a person and their task assistant in one or two plain sentences, naming the tasks touched. Reply with JSON: {\"summary\": \"...\"}", strings.Join(lines, "\n"))
	if err != nil {
		return ""
	}
	var v struct {
		Summary string `json:"summary"`
	}
	if i, j := strings.Index(out, "{"), strings.LastIndex(out, "}"); i >= 0 && j > i {
		json.Unmarshal([]byte(out[i:j+1]), &v)
	}
	return v.Summary
}
