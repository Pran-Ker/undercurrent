# The API

Base URL: `http://<host>:8787`. JSON in, JSON out. Every write names who did it in the `X-Actor`
header: `user` (the default), `agent:<run id>`, or `live:<conversation id>`; every write leaves an
event. Ids are four characters. Dates are `YYYY-MM-DD`; timestamps are UTC RFC 3339.

A **task**:

```json
{
  "id": "k79l", "stage": "staged", "text": "Book the dentist", "context": "mornings only, Elm street",
  "priority": "M", "due": "2026-10-20", "tags": ["health"], "note": "",
  "parent_id": "", "created_by": "user", "entry": "2026-10-11", "done": "", "updated_at": "2026-10-11T19:02:11Z"
}
```

`stage` is `unstaged` · `staged` · `committed` · `closed`. `created_by` is `user`, `agent` or `live`.

A **run** is one agent at work on one task:

```json
{"id": "r1x9", "task_id": "k79l", "kind": "commit", "status": "needs_you", "question": "Which card should pay?",
 "answer": "", "steps": [{"at": "…", "kind": "agent", "cmd": "claude -p --output-format json", "exit": 0, "ms": 41200, "output": "…"}],
 "result": "", "cost_cents": 0, "started_at": "…", "ended_at": ""}
```

`kind` is `commit` or `retransform`; `status` is `queued` · `running` · `needs_you` · `done` · `failed`.

An **event**:

```json
{"id": 7, "at": "2026-10-11T19:02:11Z", "actor": "user", "action": "stage", "task_id": "k79l", "run_id": "",
 "before": { "…task before" }, "after": { "…task after" }, "note": ""}
```

Actions: `seeded`, `add`, `stage`, `edit`, `close`, `commit`, `retransform`, `ask`, `answer`, `hand_back`, `restore`, `call`.

## The board

| Method and path | Body | Returns | Notes |
|---|---|---|---|
| `GET /health` | | `{ok, tasks}` | |
| `GET /tasks?stage=` | | `[task]` | all stages when omitted, in the order written down |
| `GET /tasks/:id` | | `task` | 404 when missing |
| `POST /tasks` | `{text, tags?, priority?, due?, context?, stage?, parent_id?}` | `task` (201) | lands `unstaged`; `stage: "staged"` with a `context` lands staged |
| `PATCH /tasks/:id` | `{text?, context?, tags?}` | `task` | a direct edit; refused on a closed task (409) |
| `POST /tasks/:id/stage` | `{context}` | `task` | unstaged → staged; staging again replaces the context |
| `POST /tasks/:id/close` | | `task` | refused when committed or already closed (409) |

## Runs

| Method and path | Body | Returns | Notes |
|---|---|---|---|
| `POST /tasks/:id/commit` | | `run` (202) | staged → committed; the agent command runs (a goroutine; synchronous when `UNDERCURRENT_SYNC_RUNS=1`). Done: the task closes with the agent's note and an optional next step lands unstaged with `parent_id`. Needs you: the run waits with a question. Failed: the task returns to staged with the failure in its note |
| `POST /tasks/:id/retransform` | `{instruction}` | `{run, say}` | the chat model turns the instruction into operations — rewrite, enrich, split, complete with a next step — applied as events by the run; 502 with the run when the model gives none |
| `GET /runs?task=` | | `[run]` | newest first |
| `GET /runs/:id` | | `run` | |
| `POST /runs/:id/answer` | `{answer}` | `run` (202) | resumes a `needs_you` run; the agent is invoked again with its question and the answer |

The agent command is `AGENT_CMD` (default `claude -p --output-format json`): it reads the prompt on
stdin and must end its reply with one line, `UNDERCURRENT: {"outcome": "done" | "needs_you" |
"failed", "note": "…", "question": "…", "next": "…", "next_context": "…"}`. A failed invocation
is retried three times with backoff; every attempt is a step on the run.

## Time

| Method and path | Returns | Notes |
|---|---|---|
| `GET /events?task=&actor=&since=` | `[event]` | oldest first |
| `GET /state?at=<timestamp>` | `{at, tasks}` | the board as it was: each task as its last event at or before `at` left it |
| `GET /who-did-what?since=` | `{since, actors: [{actor, actions, tasks, last_at}]}` | last 24 h by default |
| `POST /restore?at=` | `{at, restored, closed}` | compensating `restore` events; a task that did not exist then is closed with a note; committed tasks are left to their run; nothing is deleted |

## Live

| Method and path | Body | Returns | Notes |
|---|---|---|---|
| `POST /live/tools/:name` | the tool's arguments, plus `conversation_id` | `{ok, result}` · `{ok: false, needs_confirmation, read_back}` · `{ok: false, error}` | requires header `X-Live-Secret`; tools: `list_board`, `add_task`, `stage_task`, `commit_task`, `retransform`, `edit_task`, `close_task`, `answer_agent`, `recall`. `ref` is a task id or enough of its words. Key tools (`commit_task`, `retransform`, `edit_task`, `close_task`) answer with a read-back until called again with `confirmed: true`. The ElevenLabs agent's tools are client tools: the page or the app receives each call and forwards it here |
| `GET /live/config` | | `{agent_id, secret, configured, tools}` | what the page or the app needs to run a call; local only |
| `GET /live/signed-url` | | `{signed_url, agent_id}` | starts a private conversation; needs `ELEVENLABS_API_KEY` and `ELEVENLABS_AGENT_ID` |
| `POST /live/post-call` | `{type: "post_call_transcription", data: {conversation_id, transcript, analysis}}` | `{ok}` | from the page when a call ends (unsigned), or from an ElevenLabs post-call webhook (verified with `ELEVENLABS_WEBHOOK_SECRET`: `ElevenLabs-Signature: t=…,v0=…`, HMAC-SHA256 of `t.body`, 30 min). Becomes a live session and one `call` event; a missing summary is written by the chat model |

## For the app

- Refetch `GET /tasks` and `GET /runs` on focus and after each action; poll every few seconds while
  a task is committed. There is no push.
- A committed task's card reads its run from `GET /runs?task=<id>`: `needs_you` carries the
  question; `POST /runs/:id/answer` resumes it.
- CORS is open; no auth beyond the actor header for now (one user per install).
