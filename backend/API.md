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

`stage` is `unstaged` · `staged` · `committed` · `closed`.

## Built

| Method and path | Body | Returns | Notes |
|---|---|---|---|
| `GET /health` | | `{ok, tasks}` | |
| `GET /tasks?stage=` | | `[task]` | all stages when `stage` is omitted, in the order written down |
| `GET /tasks/:id` | | `task` | 404 when missing |
| `POST /tasks` | `{text, tags?, priority?, due?, context?, stage?, parent_id?}` | `task` (201) | lands `unstaged`; `stage: "staged"` with a `context` lands staged |
| `PATCH /tasks/:id` | `{text?, context?, tags?}` | `task` | a direct edit, no agent; refused on a closed task (409) |
| `POST /tasks/:id/stage` | `{context}` | `task` | unstaged → staged; staging again replaces the context |
| `POST /tasks/:id/close` | | `task` | refused when committed (the agent's) or already closed (409) |
| `GET /events?task=&actor=` | | `[event]` | oldest first |

An **event**:

```json
{"id": 7, "at": "2026-10-11T19:02:11Z", "actor": "user", "action": "stage", "task_id": "k79l",
 "before": { "...task before" }, "after": { "...task after" }, "note": ""}
```

Actions so far: `add`, `stage`, `edit`, `close`.

## Not built yet — these return 501 with `{"error": "not built yet"}`

| Method and path | Body | Will do |
|---|---|---|
| `POST /tasks/:id/commit` | | staged → committed; queues a `commit` run |
| `POST /tasks/:id/retransform` | `{instruction}` | queues a `retransform` run that rewrites, enriches, splits, or completes and yields the next |
| `GET /runs`, `GET /runs/:id` | | runs with status `queued · running · needs_you · done · failed`, their steps and question |
| `POST /runs/:id/answer` | `{answer}` | resumes a `needs_you` run |
| `GET /state?at=<timestamp>` | | the board as it was then |
| `GET /who-did-what?since=` | | events grouped by actor |
| `POST /restore?at=` | | compensating events back to that moment |
| `POST /live/tools/:name` | ElevenLabs webhook tool payload | the live agent's tools; key ones answer with a read-back until `confirmed: true` |
| `GET /live/signed-url` | | a signed URL for the app and the widget to start a call |
| `POST /live/post-call` | ElevenLabs post-call webhook | stores the transcript as a `live_session` |

## For the app

- Poll or refetch `GET /tasks` on focus and after each action; there is no push yet.
- The card for a `committed` task will read its run from `GET /runs?task=` once runs exist; until
  then committed is empty.
- CORS is open; no auth beyond the actor header for now (one user per install).
