package runs

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/pran-ker/undercurrent/backend/internal/store"
)

// An Op is one thing a retransform does to a staged task, as the user's words implied it.
type Op struct {
	Op       string  `json:"op"` // rewrite · enrich · split · complete
	Text     string  `json:"text,omitempty"`
	Context  string  `json:"context,omitempty"`
	Note     string  `json:"note,omitempty"`
	Children []child `json:"children,omitempty"`
	Next     *child  `json:"next,omitempty"`
}

type child struct {
	Text    string `json:"text"`
	Context string `json:"context,omitempty"`
}

const retransformSystem = `You turn a person's instruction about one task on their board into operations. Reply with JSON only:
{"ops": [ ... ], "say": "<one short sentence for the person>"}
Each op is one of:
  {"op": "rewrite", "text": "<the task's new words>"}
  {"op": "enrich", "context": "<text to append to the task's context>"}
  {"op": "split", "children": [{"text": "...", "context": "..."}, ...]}      — the task closes, the children are staged
  {"op": "complete", "note": "<what was done>", "next": {"text": "...", "context": "..."}}   — next is optional
Only what the instruction says; never invent facts. Keep every text short and in the person's own words where possible.`

// Retransform applies the user's instruction to a staged task through the chat model. The run is
// recorded like any other; every applied op is an event by the run.
func (r *Runner) Retransform(t store.Task, instruction, actor string) (store.Run, string, error) {
	run, err := r.S.NewRun(t.ID, "retransform")
	if err != nil {
		return run, "", err
	}
	run.Status = "running"
	r.S.PutRun(run)
	r.S.RecordRun(actor, "retransform", run.ID, &t, &t, instruction)
	user := fmt.Sprintf("TASK %s: %s\nCONTEXT: %s\nNOTES: %s\n\nINSTRUCTION: %s", t.ID, t.Text, t.Context, t.Note, instruction)
	if r.Chat == nil {
		return r.retransformFailed(run, "no chat model configured (OPENROUTER_API_KEY)")
	}
	raw, err := r.Chat(retransformSystem, user)
	run.Steps = append(run.Steps, store.Step{At: store.Now(), Kind: "model", Output: clip(raw, 20000)})
	if err != nil {
		return r.retransformFailed(run, err.Error())
	}
	var plan struct {
		Ops []Op   `json:"ops"`
		Say string `json:"say"`
	}
	if err := json.Unmarshal([]byte(extractJSON(raw)), &plan); err != nil || len(plan.Ops) == 0 {
		return r.retransformFailed(run, "the model gave no operations")
	}
	agent := "agent:" + run.ID
	for _, op := range plan.Ops {
		cur, _, _ := r.S.Task(t.ID)
		before := cur
		switch op.Op {
		case "rewrite":
			if strings.TrimSpace(op.Text) == "" {
				continue
			}
			cur.Text = strings.TrimSpace(op.Text)
			r.S.Put(cur)
			after, _, _ := r.S.Task(t.ID)
			r.S.RecordRun(agent, "edit", run.ID, &before, &after, "rewrite")
		case "enrich":
			if strings.TrimSpace(op.Context) == "" {
				continue
			}
			cur.Context = joinNote(cur.Context, op.Context)
			r.S.Put(cur)
			after, _, _ := r.S.Task(t.ID)
			r.S.RecordRun(agent, "edit", run.ID, &before, &after, "enrich")
		case "split":
			if len(op.Children) == 0 {
				continue
			}
			for _, c := range op.Children {
				k, err := r.S.Add(store.Task{Text: strings.TrimSpace(c.Text), Context: c.Context, Tags: cur.Tags, Stage: "staged", ParentID: cur.ID, CreatedBy: "agent"})
				if err == nil {
					r.S.RecordRun(agent, "add", run.ID, nil, &k, "split from "+cur.ID)
				}
			}
			cur.Stage, cur.Done = "closed", store.Today()
			cur.Note = joinNote(cur.Note, fmt.Sprintf("split into %d", len(op.Children)))
			r.S.Put(cur)
			after, _, _ := r.S.Task(t.ID)
			r.S.RecordRun(agent, "close", run.ID, &before, &after, "split")
		case "complete":
			cur.Stage, cur.Done = "closed", store.Today()
			cur.Note = joinNote(cur.Note, op.Note)
			r.S.Put(cur)
			after, _, _ := r.S.Task(t.ID)
			r.S.RecordRun(agent, "close", run.ID, &before, &after, op.Note)
			if op.Next != nil && strings.TrimSpace(op.Next.Text) != "" {
				k, err := r.S.Add(store.Task{Text: strings.TrimSpace(op.Next.Text), Context: op.Next.Context, Tags: cur.Tags, Stage: stageFor(op.Next.Context), ParentID: cur.ID, CreatedBy: "agent"})
				if err == nil {
					r.S.RecordRun(agent, "add", run.ID, nil, &k, "the next step")
				}
			}
		}
		run.Steps = append(run.Steps, store.Step{At: store.Now(), Kind: "op", Note: op.Op})
	}
	run.Status, run.Result, run.EndedAt = "done", plan.Say, store.Now()
	r.S.PutRun(run)
	return run, plan.Say, nil
}

// stageFor: a next step that arrives with context is staged; without, it waits unstaged.
func stageFor(context string) string {
	if strings.TrimSpace(context) != "" {
		return "staged"
	}
	return "unstaged"
}

func (r *Runner) retransformFailed(run store.Run, why string) (store.Run, string, error) {
	run.Status, run.Result, run.EndedAt = "failed", why, store.Now()
	r.S.PutRun(run)
	return run, "", fmt.Errorf("%s", why)
}

func extractJSON(raw string) string {
	raw = strings.TrimSpace(raw)
	raw = strings.TrimPrefix(strings.TrimSuffix(raw, "```"), "```json")
	raw = strings.TrimPrefix(raw, "```")
	if i, j := strings.Index(raw, "{"), strings.LastIndex(raw, "}"); i >= 0 && j > i {
		return raw[i : j+1]
	}
	return raw
}
