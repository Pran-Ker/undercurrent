// Package runs is the agent at work. A commit invokes a coding agent (Claude Code by default)
// directly, once per run, and reads its verdict — unless the task names a phone number, in which
// case the run is a call placed through Dial. A retransform asks the chat model for the operations
// the user's words imply and applies them. No worker, no queue: a run is a goroutine.
package runs

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/pran-ker/undercurrent/backend/internal/dial"
	"github.com/pran-ker/undercurrent/backend/internal/store"
)

type Runner struct {
	S        *store.Store
	AgentCmd []string      // AGENT_CMD: reads the prompt on stdin, prints its answer
	Sync     bool          // tests: run in the request instead of a goroutine
	Retries  int           // bounded retries on a failed invocation
	Backoff  time.Duration // between retries
	Timeout  time.Duration // one invocation
	Recall   func(string) string
	Chat     func(system, user string) (string, error) // the chat model, JSON out — for retransforms and call summaries
	Dial     *dial.Client                              // DIAL_API_KEY: a committed task that names a phone number is placed as a call
}

const Marker = "UNDERCURRENT:"

// Verdict is the last line a commit run must print: `UNDERCURRENT: {...}`.
type Verdict struct {
	Outcome     string `json:"outcome"` // done · needs_you · failed
	Note        string `json:"note"`
	Question    string `json:"question"`
	Next        string `json:"next"`
	NextContext string `json:"next_context"`
}

func New(s *store.Store) *Runner {
	cmd := os.Getenv("AGENT_CMD")
	if cmd == "" {
		cmd = "claude -p --output-format json"
	}
	return &Runner{S: s, AgentCmd: strings.Fields(cmd), Sync: os.Getenv("UNDERCURRENT_SYNC_RUNS") == "1", Retries: 3, Backoff: 2 * time.Second, Timeout: 15 * time.Minute, Chat: Chat, Dial: dial.New()}
}

// Commit hands a staged task to the agent: the task becomes committed, a run is queued and started.
func (r *Runner) Commit(t store.Task, actor string) (store.Run, error) {
	before := t
	t.Stage = "committed"
	if err := r.S.Put(t); err != nil {
		return store.Run{}, err
	}
	run, err := r.S.NewRun(t.ID, "commit")
	if err != nil {
		return run, err
	}
	after, _, _ := r.S.Task(t.ID)
	r.S.RecordRun(actor, "commit", run.ID, &before, &after, "")
	r.start(run.ID)
	return run, nil
}

// Answer resumes a run that asked.
func (r *Runner) Answer(run store.Run, answer, actor string) (store.Run, error) {
	run.Answer, run.Status = answer, "running"
	run.Steps = append(run.Steps, store.Step{At: store.Now(), Kind: "answer", Note: answer})
	if err := r.S.PutRun(run); err != nil {
		return run, err
	}
	t, _, _ := r.S.Task(run.TaskID)
	r.S.RecordRun(actor, "answer", run.ID, &t, &t, answer)
	r.start(run.ID)
	return run, nil
}

func (r *Runner) start(runID string) {
	if r.Sync {
		r.execute(runID)
		return
	}
	go r.execute(runID)
}

func (r *Runner) execute(runID string) {
	run, ok, err := r.S.Run(runID)
	if err != nil || !ok {
		return
	}
	t, ok, _ := r.S.Task(run.TaskID)
	if !ok {
		return
	}
	run.Status = "running"
	r.S.PutRun(run)
	actor := "agent:" + run.ID
	if to := dial.Number(t.Text + " " + t.Context); to != "" && r.Dial != nil {
		r.call(run, t, actor, to)
		return
	}
	out, err := r.invoke(r.commitPrompt(t, run), &run)
	v, perr := parseVerdict(out)
	switch {
	case err != nil:
		r.fail(run, t, actor, "the agent could not run: "+err.Error())
	case perr != nil:
		run.Status, run.Question = "needs_you", "The agent ended without a verdict. It said: "+clip(out, 600)+" — what should happen to this task?"
		r.S.PutRun(run)
		r.S.RecordRun(actor, "ask", run.ID, &t, &t, run.Question)
	case v.Outcome == "needs_you":
		run.Status, run.Question = "needs_you", v.Question
		r.S.PutRun(run)
		r.S.RecordRun(actor, "ask", run.ID, &t, &t, v.Question)
	case v.Outcome == "done":
		r.done(run, t, actor, v)
	default:
		r.fail(run, t, actor, v.Note)
	}
}

// done closes the task with the note and adds the next step when the verdict names one.
func (r *Runner) done(run store.Run, t store.Task, actor string, v Verdict) {
	before := t
	t.Stage, t.Done = "closed", store.Today()
	t.Note = joinNote(t.Note, v.Note)
	r.S.Put(t)
	after, _, _ := r.S.Task(t.ID)
	r.S.RecordRun(actor, "close", run.ID, &before, &after, v.Note)
	if strings.TrimSpace(v.Next) != "" {
		child, err := r.S.Add(store.Task{Text: strings.TrimSpace(v.Next), Context: v.NextContext, Tags: t.Tags, ParentID: t.ID, CreatedBy: "agent"})
		if err == nil {
			r.S.RecordRun(actor, "add", run.ID, nil, &child, "the next step")
		}
	}
	run.Status, run.Result, run.EndedAt = "done", v.Note, store.Now()
	r.S.PutRun(run)
}

// call is the run for a task that names a phone number: Dial places the call with the task as the
// voice agent's instruction; the transcript becomes the run's step and the next task, review notes.
// A call that was not completed — busy, unanswered, failed — hands the task back.
func (r *Runner) call(run store.Run, t store.Task, actor, to string) {
	started := time.Now()
	c, err := r.Dial.Place(to, callInstruction(t), run.ID)
	if err != nil {
		run.Steps = append(run.Steps, store.Step{At: store.Now(), Kind: "call", Exit: 1, Ms: time.Since(started).Milliseconds(), Note: "to " + to, Output: err.Error()})
		r.S.PutRun(run)
		r.fail(run, t, actor, "could not place the call: "+err.Error())
		return
	}
	c, err = r.Dial.Wait(c.ID, r.Timeout)
	outcome := c.Status.TerminationType
	if err != nil {
		outcome = err.Error()
	}
	exit := 1
	if outcome == "completed" {
		exit = 0
	}
	run.Steps = append(run.Steps, store.Step{At: store.Now(), Kind: "call", Cmd: c.ID, Exit: exit, Ms: time.Since(started).Milliseconds(), Note: fmt.Sprintf("to %s · %s · %ds", to, outcome, c.Duration), Output: c.Transcript})
	r.S.PutRun(run)
	r.S.RecordRun(actor, "call", run.ID, &t, &t, fmt.Sprintf("called %s: %s, %ds", to, outcome, c.Duration))
	if outcome != "completed" {
		r.fail(run, t, actor, "the call was not completed: "+outcome)
		return
	}
	note := r.callSummary(to, c)
	r.done(run, t, actor, Verdict{Outcome: "done", Note: note, Next: "Review call notes: " + t.Text,
		NextContext: fmt.Sprintf("Call to %s on %s, %ds. %s\n\n%s", to, store.Today(), c.Duration, note, transcriptText(c))})
}

func callInstruction(t store.Task) string {
	var b strings.Builder
	b.WriteString("You are a personal assistant placing a call on your principal's behalf. The task you are calling about: ")
	b.WriteString(strings.TrimSpace(t.Text))
	if t.Context != "" {
		b.WriteString("\nWhat the principal added: " + t.Context)
	}
	if t.Note != "" {
		b.WriteString("\nNotes so far: " + t.Note)
	}
	b.WriteString("\nOpen by saying who you are calling for and why. Get what the task needs — an answer, a booking, a confirmation — and repeat it back. Say only what the task gives you; if asked something it does not cover, say the principal will follow up. Be brief and warm, and end the call once the task is handled.")
	return b.String()
}

// callSummary is one or two sentences from the chat model about the call, or the bare facts.
func (r *Runner) callSummary(to string, c dial.Call) string {
	plain := fmt.Sprintf("Called %s; the call lasted %ds.", to, c.Duration)
	if r.Chat == nil || strings.TrimSpace(c.Transcript) == "" {
		return plain
	}
	out, err := r.Chat(`Summarize this phone call an assistant made on someone's behalf in one or two plain sentences: what was asked, what was agreed, anything left open. Reply with JSON: {"summary": "..."}`, c.Transcript)
	if err != nil {
		return plain
	}
	var v struct {
		Summary string `json:"summary"`
	}
	if i, j := strings.Index(out, "{"), strings.LastIndex(out, "}"); i >= 0 && j > i {
		json.Unmarshal([]byte(out[i:j+1]), &v)
	}
	if strings.TrimSpace(v.Summary) == "" {
		return plain
	}
	return strings.TrimSpace(v.Summary)
}

func transcriptText(c dial.Call) string {
	if strings.TrimSpace(c.Transcript) == "" {
		return "No transcript came back."
	}
	return "TRANSCRIPT\n" + strings.TrimSpace(c.Transcript)
}

func (r *Runner) fail(run store.Run, t store.Task, actor, why string) {
	before := t
	t.Stage = "staged"
	t.Note = joinNote(t.Note, "run failed: "+why)
	r.S.Put(t)
	after, _, _ := r.S.Task(t.ID)
	r.S.RecordRun(actor, "hand_back", run.ID, &before, &after, why)
	run.Status, run.Result, run.EndedAt = "failed", why, store.Now()
	r.S.PutRun(run)
}

// invoke runs the agent command with the prompt on stdin, retrying a failed invocation a bounded
// number of times; every attempt is a step on the run.
func (r *Runner) invoke(prompt string, run *store.Run) (string, error) {
	var out string
	var err error
	for attempt := 0; attempt <= r.Retries; attempt++ {
		kind := "agent"
		if attempt > 0 {
			kind = "retry"
			time.Sleep(r.Backoff)
		}
		started := time.Now()
		out, err = r.once(prompt)
		var cents int
		out, cents = unwrap(out)
		run.CostCents += cents
		exit := 0
		if ee, ok := err.(*exec.ExitError); ok {
			exit = ee.ExitCode()
		} else if err != nil {
			exit = -1
		}
		run.Steps = append(run.Steps, store.Step{At: store.Now(), Kind: kind, Cmd: strings.Join(r.AgentCmd, " "), Exit: exit, Ms: time.Since(started).Milliseconds(), Output: clip(out, 20000)})
		r.S.PutRun(*run)
		if err == nil {
			return out, nil
		}
	}
	return out, err
}

func (r *Runner) once(prompt string) (string, error) {
	if len(r.AgentCmd) == 0 {
		return "", fmt.Errorf("AGENT_CMD is empty")
	}
	ctx, cancel := context.WithTimeout(context.Background(), r.Timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, r.AgentCmd[0], r.AgentCmd[1:]...)
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Env = without(os.Environ(), "CLAUDECODE") // a nested Claude Code refuses to start otherwise
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return string(out) + string(ee.Stderr), err
		}
		return string(out), err
	}
	return string(out), nil
}

func (r *Runner) commitPrompt(t store.Task, run store.Run) string {
	var b strings.Builder
	b.WriteString("You are working one task from a personal task board on the owner's behalf. Do what the task asks as far as you can from this machine — research, write, prepare, draft — and report honestly.\n\n")
	fmt.Fprintf(&b, "TASK %s: %s\n", t.ID, t.Text)
	if t.Context != "" {
		fmt.Fprintf(&b, "CONTEXT (what the owner added when staging it): %s\n", t.Context)
	}
	if len(t.Tags) > 0 {
		fmt.Fprintf(&b, "TAGS: %s\n", strings.Join(t.Tags, " "))
	}
	if t.Due != "" {
		fmt.Fprintf(&b, "DUE: %s\n", t.Due)
	}
	if t.Note != "" {
		fmt.Fprintf(&b, "NOTES SO FAR:\n%s\n", t.Note)
	}
	if r.Recall != nil {
		if rec := r.Recall(t.Text + " " + t.Context); rec != "" {
			fmt.Fprintf(&b, "\nRELATED, from the owner's board and conversations:\n%s\n", rec)
		}
	}
	if run.Question != "" {
		fmt.Fprintf(&b, "\nYOU ASKED: %s\nTHE OWNER ANSWERED: %s\n", run.Question, run.Answer)
	}
	b.WriteString(`
RULES
- Never claim to have done something you did not do. If it needs the owner (a decision, a payment, a login), stop and ask one question.
- Write a short note of what you did and found: it is what the owner reads next.
- If finishing this task reveals the obvious next step, name it.

END your reply with exactly one line, the verdict, and nothing after it:
` + Marker + ` {"outcome": "done" | "needs_you" | "failed", "note": "<what you did, 1-4 sentences>", "question": "<only when needs_you>", "next": "<the next step as a task, or empty>", "next_context": "<context for it, or empty>"}
`)
	return b.String()
}

// unwrap takes the agent's reply out of Claude Code's `--output-format json` envelope, with the
// cost it reports in cents; a plain-text agent's output passes through.
func unwrap(out string) (string, int) {
	text := strings.TrimSpace(out)
	var env struct {
		Result string  `json:"result"`
		Cost   float64 `json:"total_cost_usd"`
	}
	if strings.HasPrefix(text, "{") && json.Unmarshal([]byte(text), &env) == nil && env.Result != "" {
		return env.Result, int(env.Cost*100 + 0.5)
	}
	return text, 0
}

// parseVerdict reads the marker line out of the agent's reply.
func parseVerdict(out string) (Verdict, error) {
	var v Verdict
	text, _ := unwrap(out)
	i := strings.LastIndex(text, Marker)
	if i < 0 {
		return v, fmt.Errorf("no verdict line")
	}
	rest := strings.TrimSpace(text[i+len(Marker):])
	if j := strings.LastIndex(rest, "}"); j >= 0 {
		rest = rest[:j+1]
	}
	if err := json.Unmarshal([]byte(rest), &v); err != nil {
		return v, fmt.Errorf("verdict is not JSON: %w", err)
	}
	switch v.Outcome {
	case "done", "needs_you", "failed":
		return v, nil
	}
	return v, fmt.Errorf("verdict outcome %q", v.Outcome)
}

func joinNote(a, b string) string {
	b = strings.TrimSpace(b)
	if b == "" {
		return a
	}
	if a == "" {
		return b
	}
	return a + "\n" + b
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func without(env []string, key string) []string {
	out := env[:0:0]
	for _, kv := range env {
		if !strings.HasPrefix(kv, key+"=") {
			out = append(out, kv)
		}
	}
	return out
}
