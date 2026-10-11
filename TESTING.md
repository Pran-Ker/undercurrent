# Testing

Integration tests drive the real HTTP API against a scratch database. The agent command is a
scripted shell counterpart that reads the prompt and prints a scripted verdict (and can fail on
cue); the chat model is an HTTP server answering with scripted operations; the voice platform is
simulated by calling the live endpoints with a real secret and a real signature. Nothing in a test
pretends silently: every counterpart behaves like the real thing on the wire, and every check is on
the database afterwards. Each integration test has one diagram of the flow it holds.

Run: `cd backend && go test ./...`

## I1 · commit runs the agent and yields the next step — `TestI1CommitRunsTheAgentAndYieldsTheNextStep`

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant G as agent command
  participant D as database
  U->>A: POST /tasks, POST /tasks/:id/stage (context)
  U->>A: POST /tasks/:id/commit
  A->>D: stage = committed, run queued, event commit
  A->>G: prompt on stdin (task, context, the verdict contract)
  G-->>A: UNDERCURRENT: {outcome done, note, next}
  A->>D: task closed with the note, event close by agent:run
  A->>D: next step added unstaged with parent_id, event add
  U->>A: GET /runs/:id, GET /tasks?stage=unstaged
  A-->>U: run done with one agent step, the next step on the board
```

## I2 · retransform completes and yields the next — `TestI2RetransformCompletesAndYieldsTheNext`

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant M as chat model
  participant D as database
  U->>A: POST /tasks/:id/retransform (the forms are filled, now post them)
  A->>M: task, context, instruction, the operations contract
  M-->>A: ops complete with a next step, say
  A->>D: task closed with the note, event close by agent:run
  A->>D: next step added staged with its context, event add
  A-->>U: run done, say
```

## I3 · retransform splits into children — `TestI3RetransformSplitsIntoChildren`

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant M as chat model
  participant D as database
  U->>A: POST /tasks/:id/retransform (split into kitchen, books, van)
  M-->>A: ops split with three children
  A->>D: three staged children with parent_id, one event add each
  A->>D: parent closed, note split into 3, event close
  U->>A: GET /tasks?stage=staged
  A-->>U: the three children
```

## I4 · direct actions leave events — `TestDirectActionsLeaveEvents`

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant D as database
  U->>A: POST /tasks (book the dentist)
  A->>D: insert task, event add
  U->>A: POST /tasks/:id/stage (context)
  A->>D: stage = staged, event stage (before, after)
  U->>A: PATCH /tasks/:id (new words)
  A->>D: text changed, event edit
  U->>A: POST /tasks/:id/close
  A->>D: stage = closed, done = today, event close
  U->>A: POST /tasks/:id/close again
  A-->>U: 409 already closed
  U->>A: GET /events?task=:id
  A-->>U: add, stage, edit, close, all by user
```

## I5 · live tools read back, then land — `TestI5LiveToolsReadBackThenLand`

```mermaid
sequenceDiagram
  participant V as voice platform (simulated)
  participant A as API
  participant G as agent command
  participant D as database
  V->>A: POST /live/tools/add_task (text, context) with the secret
  A->>D: task staged, event add by live:conv1
  V->>A: POST /live/tools/commit_task (ref dentist)
  A-->>V: needs_confirmation, read_back Commit k79l book the dentist?
  Note over V: nothing landed
  V->>A: POST /live/tools/commit_task (ref dentist, confirmed true)
  A->>D: committed, event commit by live:conv1
  A->>G: the run
  G-->>A: verdict done
  A->>D: closed, event close by agent:run
  V->>A: POST /live/tools/list_board with a wrong secret
  A-->>V: 403
```

## I6 · the agent asks, the owner answers, the run resumes — `TestI6AnAgentQuestionIsAnsweredAndTheRunResumes`

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant G as agent command
  participant D as database
  U->>A: POST /tasks/:id/commit
  A->>G: prompt
  G-->>A: UNDERCURRENT: {outcome needs_you, question which card}
  A->>D: run needs_you with the question, event ask; task stays committed
  U->>A: POST /runs/:id/answer (the business one)
  A->>D: step answer, event answer
  A->>G: prompt with YOU ASKED and THE OWNER ANSWERED
  G-->>A: UNDERCURRENT: {outcome done, note}
  A->>D: task closed, run done with three steps
```

## I7 · time travel and restore — `TestI7StateAtAMoment`

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant D as database
  U->>A: POST /tasks (first)
  Note over A,D: t1
  U->>A: POST /tasks (second), POST /tasks/first/stage
  Note over A,D: t2
  U->>A: POST /tasks/first/close
  U->>A: GET /state?at=t1
  A-->>U: one task, unstaged
  U->>A: GET /state?at=t2
  A-->>U: first staged, second unstaged
  U->>A: GET /state
  A-->>U: first closed
  U->>A: POST /restore?at=t1
  A->>D: first back to unstaged with no context (event restore), second closed with a note (event restore)
  A-->>U: restored 1, closed 1
```

## I8 · who did what — `TestI8WhoDidWhat`

```mermaid
sequenceDiagram
  participant U as user
  participant V as voice (X-Actor live:conv9)
  participant A as API
  participant G as agent command
  U->>A: add, stage, commit
  G-->>A: verdict done (close by agent:run)
  V->>A: POST /tasks (from the call)
  U->>A: GET /who-did-what
  A-->>U: user add 1 stage 1 commit 1, agent close 1, live:conv9 add 1
```

## I9 · bounded retries, then hand back — `TestI9BoundedRetriesThenHandBack`

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant G as agent command
  participant D as database
  U->>A: POST /tasks/flaky/commit
  A->>G: attempt 1
  G-->>A: exit 1
  A->>G: retry after backoff
  G-->>A: exit 1
  A->>G: retry
  G-->>A: verdict done
  A->>D: run done, steps agent:1 retry:1 retry:0
  U->>A: POST /tasks/doomed/commit
  A->>G: four attempts, all exit 1
  A->>D: run failed, task back to staged with run failed in its note, event hand_back
```

## I10 · the post-call webhook feeds recall — `TestI10PostCallWebhookFeedsRecall`

```mermaid
sequenceDiagram
  participant V as voice platform (simulated)
  participant A as API
  participant D as database
  V->>A: POST /live/post-call with a bad signature
  A-->>V: 401
  V->>A: POST /live/post-call signed t=…,v0=hmac(t.body)
  A->>D: live session (transcript, summary), event call by live:conv42
  A-->>V: 200
  V->>A: POST /live/tools/recall (landlord mornings)
  A-->>V: the session summary, cited by its conversation id
```

## I11 · a committed call task dials and leaves review notes — `TestI11CommittedCallTaskDialsAndLeavesReviewNotes`

The task says call and names a phone number, so the run is a call; a number without a call verb goes
to the agent as usual. Dial is a scripted counterpart here (a fake
REST server keyed by the number); `TestDialLiveCall` places one real call when `DIAL_LIVE_TEST=1`
and `DIAL_LIVE_TO` are set, and is skipped otherwise.

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant P as Dial
  participant M as chat model
  participant D as database
  U->>A: POST /tasks/dentist/commit  (text names +1415…)
  A->>P: POST /api/v1/calls  to, fromNumber, outboundInstruction = the task and its context, Idempotency-Key = run id
  P-->>A: call queued
  A->>P: GET /api/v1/calls/{id}  until Terminated and the transcript has landed
  P-->>A: completed, 83s, transcript
  A->>M: summarize the transcript
  M-->>A: one sentence
  A->>D: event call; task closed with the summary; "Review call notes: …" unstaged with the transcript as context; run done, step call exit 0
  U->>A: POST /tasks/landlord/commit  (text names +1415…99)
  A->>P: place, poll
  P-->>A: no-answer
  A->>D: event call, task back to staged with "the call was not completed: no-answer", event hand_back, run failed, no review task
  U->>A: POST /tasks/plumber/commit  ("text … +1415…77", no call verb)
  A->>A: the agent command, as for any task
```

## I12 · one agent works the queue; a question parks the task — `TestI12OneAgentWorksTheQueueAndAQuestionParksTheTask`

The only test on the real queue (the others run the agent in the request). The scripted agent's
lines are consumed in order, which is how the test knows the gym was taken first.

```mermaid
sequenceDiagram
  participant U as user
  participant A as API
  participant Q as the one agent (queue)
  participant G as agent command
  participant V as voice agent
  U->>A: POST /tasks/gym/commit, POST /tasks/weather/commit
  A->>Q: run 1, run 2 queued in that order
  Q->>G: run 1 · gym
  G-->>Q: needs_you "Did you go to the gym?"
  Q->>A: run 1 parked, gym stays committed; next
  Q->>G: run 2 · weather
  G-->>Q: done "sunny, 61°F"
  Q->>A: weather closed with the note
  V->>A: GET /live/config — the board text ends with the waiting question
  U->>A: POST /runs/1/answer "yes, this morning"
  A->>Q: run 1 queued again
  Q->>G: run 1 with the answer
  G-->>Q: done "the owner went"
  Q->>A: gym closed
```

## Smaller tests

- The demo set takes its stages from the migration: 16 unstaged, 22 staged, 4 closed — `TestTheDemoSetTakesItsStages`
- Planned: `state(at)` on an empty log; the Keewano payload builder emits only registered ids
  (needs no key — `Payload` is exported for it); legal transitions only.
