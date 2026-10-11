# The mobile app

One screen, three cards, one call button. The app is a way of moving cards on the board and of
talking to the agent that moves them for you. It talks to the backend over HTTPS (`backend/API.md`)
and to the voice agent through the ElevenLabs React Native SDK; it never opens the database.

## Reaching the backend

The backend is one Go process; the app needs a URL to it and the key it was started with.

| Where the backend runs | URL for the app | Notes |
|---|---|---|
| A laptop, for a developer | `http://<laptop ip>:8787` on the same network | no key needed unless `UNDERCURRENT_API_KEY` is set; `adb reverse tcp:8787 tcp:8787` works for an Android device on USB |
| The shared dev backend on Railway | `https://<service>.up.railway.app` | always keyed; built from the `Dockerfile` at the repo root; the queue and the agent run there too (pi on OpenRouter, see the Dockerfile) |

**Every request carries the key** when the backend has one: `Authorization: Bearer <key>` (or
`X-Api-Key: <key>`). Only `GET /health` is open. A missing or wrong key is a 401 with a message.
The key is handed to the app's developers out of band and lives in the app's env, never in the
repo. One more header, `X-Actor`, names who acted (`user` from the app) and shows in who-did-what.

Standing up a dev backend on Railway, from the repo root:

```sh
railway init -n undercurrent-dev
railway variables --set TURSO_DATABASE_URL=… --set TURSO_AUTH_TOKEN=… \
  --set ELEVENLABS_API_KEY=… --set ELEVENLABS_AGENT_ID=… --set LIVE_TOOL_SECRET=… \
  --set OPENROUTER_API_KEY=… --set UNDERCURRENT_API_KEY="$(openssl rand -hex 24)"
railway up --detach && railway domain
```

Optional on top: `DIAL_API_KEY` and `DIAL_FROM_NUMBER` (calls out), `KEEWANO_SDK_KEY` (analytics).
Everything is off without its key and fails on its own (README, "Integrations fail on their own").

## The live conversation, end to end

The voice runs between the phone and ElevenLabs; the backend owns the agent, the tools and the
board. The app is the bridge for tool calls, which is why the backend needs no inbound webhook.

```mermaid
sequenceDiagram
  participant P as app
  participant B as backend
  participant E as ElevenLabs
  P->>B: GET /live/config  (key)
  B-->>P: agent_id, secret, tools[], board (text)
  P->>B: GET /live/signed-url  (key)
  B-->>P: signed_url
  P->>E: startSession({signedUrl, clientTools, dynamicVariables: {user_id, board}})
  E-->>P: onConnect {conversationId}
  Note over P,E: the person talks; the agent knows the whole board from the first word
  E->>P: client tool call, e.g. move_task {ref, stage}
  P->>B: POST /live/tools/move_task  {ref, stage, conversation_id}  (key + X-Live-Secret)
  B-->>P: {ok, result} · or {needs_confirmation, read_back} · or {error}
  P-->>E: the result string, spoken by the agent
  P->>B: GET /tasks — refresh the cards right after every tool call
  E-->>P: onDisconnect
  P->>B: POST /live/post-call {type: "post_call_transcription", data: {conversation_id, transcript, analysis: {}}}  (key)
```

What the app does, concretely:

1. `GET /live/config` → `agent_id`, `secret`, `tools` (the tool names), `board` (every task as text,
   with the questions the agent is waiting on at the end).
2. `GET /live/signed-url` → `signed_url`. The app never holds an ElevenLabs key.
3. `Conversation.startSession({ signedUrl, clientTools, dynamicVariables: { user_id, board } })`
   where `clientTools` maps **each name in `tools`** to a function that POSTs its parameters plus
   `conversation_id` to `/live/tools/<name>` with `X-Live-Secret: <secret>` and the key, and
   returns a string: `result` when `ok`, else
   `"NEEDS CONFIRMATION — read this back and wait for a yes: " + read_back`, else `"ERROR: " + error`.
   Refresh the cards after every tool call: that is how "move build the bookshelf to done" shows
   up on screen while the agent is still talking.
4. Keep the transcript from `onMessage` (`{message, role}`; `role` is `user` or `agent`). On
   `onDisconnect`, POST it to `/live/post-call` as above; the backend keeps the session, writes a
   one-line summary and records a `call` event.
5. The read-back: a key action's first tool call returns `needs_confirmation`; the agent reads it
   aloud and calls again with `confirmed: true` after a yes. The app only shows the read-back and
   may offer Yes / No buttons that speak the word for the person.

The tools, as the agent sees them: `list_board`, `add_task`, `stage_task` (with context),
`move_task` (unstaged or staged, reopens a closed task by id), `commit_task`, `retransform`,
`edit_task`, `close_task`, `answer_agent` (the reply to a question the agent is waiting on),
`recall`. The page in `backend/internal-web-ui/index.html` is the reference implementation of
exactly this flow in a hundred lines; copy its `runTool` and `startSession` call.

## Screens

**Home** — three stacked cards, each a list:

| Card | Shows | Tap a row |
|---|---|---|
| Unstaged | tasks written down, nothing decided | opens the task; the main button is **Stage** (asks for context) |
| Staged | tasks with context, ready | opens the task; buttons **Commit to agent**, **Retransform**, **Close** |
| Running | committed tasks with their run status: running · needs you · done | opens the run; a **needs you** row shows the question and an answer box |

Below them a **Closed** sheet (pull up), and a floating **Add** button (one text field, lands
unstaged). A **Call** button at the top opens the call screen.

**Task** — text, context (editable), tags, notes (what runs wrote), the lineage (parent and
children), and the buttons for its stage. Editing text or context is a direct edit — one request,
no agent.

**Retransform** — a text box: "the first half is done, the rest is X", "split this into three",
"add that the landlord prefers mornings". Sends `POST /tasks/:id/retransform`; the result shows
as the board changing (a closed task and a new staged one, three children, richer context).

**Run** — the question if there is one, the answer box, the steps the agent took, the note it
wrote, the next task it yielded.

**Call** — full screen: status (connecting · listening · speaking), a transcript strip with the
last lines, the agent's read-back as text with **Yes** / **No** buttons (also answerable by
voice), and hang up. The flow is the one in "The live conversation, end to end" above.

**Time travel** — a sidebar, not a tab: it is rare. The last 20 actions from
`GET /events?limit=20` as a list; tapping one renders `GET /state?at=<that event's at>`, the board
as it was right after it, read-only, with a "back to now" button. Restore (`POST /restore?at=`) can
stay out of the app.

## Flows the app must support

1. Add → appears unstaged.
2. Stage: tap an unstaged task, write context, confirm → moves to Staged.
3. Commit: tap a staged task, **Commit to agent** → moves to Running; later the run ends done
   (task closed, maybe a new unstaged child) or asks a question (row says **needs you**).
4. Answer: open the needs-you run, type or say the answer → run resumes.
5. Retransform: tap a staged task, describe the change → board updates.
6. Direct edit and close without any agent.
7. Call: "put the dentist on the board and commit it" → the agent reads it back → Yes → done.
   Nothing above *add* and *stage* happens on a call without the read-back.
8. Time travel: the sidebar above — the last 20 actions, each a moment the board can be shown at.

## Confirmation rule

The backend enforces it: on a call, commit, close, edit, split and complete answer with a
read-back until the tool is called again with `confirmed: true`. The app only needs to show the
read-back and offer Yes / No; the agent handles the second call. Add, stage and answering a
question need no confirmation.

## Stack

Expo (dev build, not Expo Go — the ElevenLabs SDK needs native modules), `@elevenlabs/react-native`
with the LiveKit packages from their Expo guide, `fetch` against `BACKEND_URL`. No local database:
the board is fetched on focus and after every action; the backend is the truth.

## Environment

```
EXPO_PUBLIC_BACKEND_URL=https://<service>.up.railway.app   # or http://<laptop ip>:8787
EXPO_PUBLIC_BACKEND_KEY=<the UNDERCURRENT_API_KEY of that backend>
```

The agent id and signed URLs come from the backend, so the app holds no ElevenLabs key. The
backend key is the only secret the app carries.

## What is not in the app

Erase (closed is closed), tags editing beyond text, multi-user, offline queues.
