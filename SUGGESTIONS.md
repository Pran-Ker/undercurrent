# Suggestions

What the references teach, and what to take from each. Sources are the products' own pages and
decks, read on 2026-10-11.

## Instinct — instinct.com

A personal assistant you text or call. "There are no new interfaces": it uses a phone and a
computer the way a person does. Its examples are errands — dispute a bill, send a gift, order
groceries, book the doctor, plan a weekend.

- **Take:** the errand catalogue as the kind of task a committed run should handle; the promise
  that the user never learns a new interface — the board is for seeing, the voice is for doing.
- **Leave:** acting without a visible record. Our runs end with a note and an event.

## Grok Bot — x.ai/bot/guides/engineering

Work goes on a board; each bot is an always-on teammate with its own computer; bots launch cloud
agents, watch PRs, post updates in one channel per project; when a PR is ready the bot pings you
and stops. Humans own review and merge. A nightly audit opens one cleanup PR per area.

- **Take:** "a run ends with a ping" — done with a note, or one question, never silently on;
  one channel of updates per task (the run's steps); a scheduled sweep as a later idea.
- **Leave:** fleets and rosters; one agent per committed task is enough.

## MausBot (open-source analogue)

Agents as contacts in a chat app, each with its own model; schedules on a calendar; computer use
through your own tools and logins; transcripts, keys and events kept in a local folder.

- **Take:** events and transcripts as plain local records; running the agent through tools you
  already have — which is why committed runs invoke Claude Code or Codex directly rather than a
  loop of our own.

## Darwin — darwin.so

An index of the agentic web (agents over MCP, A2A, WebMCP). `POST /api/v3/search` with a
natural-language task returns ranked agents with readiness, required setup and a connection
method; finding an agent does not start work. Act needs separate, allowlisted authorization.
Discovery, an accepted request and a confirmed outcome are three different things.

- **Take (phase 2):** a `find_agent` tool for committed runs — search, show the match and its
  setup, act only after the user approves; the three-way distinction in how a run reports what
  it did.

## Darwin AI — getdarwin.ai

Named digital workers for customer conversations over WhatsApp, Instagram and phone; human
escalation triggers; accuracy by audits, templates and automatic tests.

- **Take:** escalation as a first-class outcome of a run (`needs_you`), and a test suite that
  grades outcomes rather than transcripts.

## Temporal schedules — docs.temporal.io/schedule

A schedule spec is a calendar (day of week, day of month, hour) or an interval, with a start and
end, a time zone and jitter. Overlap policies: Skip (default), BufferOne, BufferAll, CancelOther,
TerminateOther, AllowAll. A catch-up window (default a year) replays missed runs; pause carries a
note; a schedule can be limited to N actions.

- **Take (phase 2, recurring tasks):** one live child per template and Skip as the overlap rule;
  no catch-up — missed periods are skipped; pause as a note on the template. Taken as a model,
  not as a dependency: no Temporal.

## ElevenLabs Agents

Webhook tools call our endpoints with LLM-filled parameters, secrets in headers; client tools run
in the app; MCP servers attach as is; dynamic variables personalise a call; post-call webhooks
deliver the transcript, summary and analysis with a signature to verify; agents are created and
updated by API; React and Expo SDKs; Twilio and SIP numbers for inbound and outbound calls; batch
calling; transfer to a human number.

- **Take:** the agent created from a file by a script so its tools and prompt are reviewable;
  mechanical confirmation on key tools; the post-call transcript as context the oracle can recall;
  transfer-to-number as the later escalation channel.
- **Edge cases:** a tool that times out mid-sentence; a user who says "yes" to a read-back the
  agent never gave; the post-call webhook arriving twice (dedupe on `conversation_id`).

## Keewano — docs.keewano.com

An analytics database for agents: small typed events per entity (a UUID), kept in order, each
carrying the latest value of every earlier event; custom events registered once with ids from
2000, immutable; agents query in plain English over MCP, or SQL and Lua. The SpeedHacks rubric:
a live query in the demo that changes what the product does; a measured bottleneck removed.

- **Take:** events as categories and counts, never text; one registry of event ids; a query the
  product acts on — a run that reads how often it asked the user lately and asks less when it is
  high.

## Dial — getdial.ai

A phone number for an agent: outbound calls from a plain-language instruction with the
transcript returned; SMS between Dial numbers (regular phones need 10DLC registration); iMessage
and WhatsApp by request; five-minute calls, two at a time on new accounts.

- **Take:** `call_phone` as a run tool with the instruction written by the run and the transcript
  landing in the task's note; the limits as test fixtures (a call cut at five minutes).

## Alike — alike.work

Runs inside the coding agent over hooks and MCP; at session close writes down what was decided,
why, and the alternative it beat; pushes it at the next session's start and before an edit on a
file it holds something about; transcripts go to your own store, redacted per grant before any
teammate's agent sees them; deny-only capture rules per repo.

- **Take:** the shape of context — what stands and what was ruled out — for a task's `context`
  and a run's note; writing decisions back (the user said yes); the oracle reading sessions at
  question time. Install it scoped to this repo only, with transcript capture off.

## Sparta Worlds — the starter deck

A local flight simulator for agents on business APIs: deterministic twins (Stripe, a ticket
desk), scripted runs, outcome checks on the resulting state, an injected HTTP 500 that defeats a
no-retry agent and a bounded-retry fix that passes the same checks.

- **Take:** the whole testing posture — simulate the counterpart on the wire, grade the database
  afterwards, inject one failure per flow, prove the fix on the same checks (I9).

## Edge cases to keep in view

- A task committed twice; a run that outlives the process; a run that closes a task the user
  closed meanwhile (the event log decides who was later).
- A retransform that splits a task that was already split.
- A live call that stages a task and then loses the connection before the read-back.
- Restore to a moment inside a run.
- The demo's today is 2026-09-01; the real today moves — due dates in the demo will read as
  overdue, which is fine for the board and misleading for an agent.
