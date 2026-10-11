# The mobile app

One screen, three cards, one call button. The app is a way of moving cards on the board and of
talking to the agent that moves them for you. It talks to the backend over HTTP (`backend/API.md`)
and to the live agent through the ElevenLabs React Native SDK; it never opens the database.

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
voice), and hang up. Started with a signed URL from `GET /live/signed-url` so the agent stays
private. The agent's tools are **client tools**: the SDK hands each call to the app, which forwards
it to `POST /live/tools/<name>` on the backend with the secret from `GET /live/config` and returns
the result — so the backend needs no public URL. Start the session with `dynamicVariables:
{user_id, board}` where `board` is the text from `GET /live/config`: the agent then knows every task
from the first word and the owner can say where each one should sit. When the call ends the app posts the transcript to
`POST /live/post-call`.

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
8. Time travel (nice to have): a slider that renders `GET /state?at=` — the board as it was.

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
EXPO_PUBLIC_BACKEND_URL=http://<your machine>:8787
```

The agent id and signed URLs come from the backend, so the app holds no ElevenLabs key.

## What is not in the app

Erase (closed is closed), tags editing beyond text, multi-user, offline queues.
