# What Stone needs from OCX's message layer

Stone is the iPhone client for working with agents and people on a Fossil
repository. It is meant to work for any remote agent or user interface that
lives on top of Fossil. Stone keeps a full clone, reads it with its own
queries, writes into it while offline, and relies on `fossil sync` to deliver.
It can't run `ocx2`, a server daemon or any other program on the phone, and it
is often off the network.

So everything Stone shows about agents has to be readable from the clone. And
everything Stone does for the user has to be something it can write into the
clone and sync later. Live server endpoints can add freshness on top, but
Stone can't depend on them. This doc records what Stone had before the `ocx2`
redesign, what it has now, and what the message layer has to define for those
features to come back. Asked for by the maintainer, 2026-10-21, on run
332c8a30ba.

## What Stone had, and what it has now

| Feature | Before (ollama-codex daemon) | Now |
|---|---|---|
| Agent working / idle / stopped dot | `GET /ext/ocx/status?thread=` ([ocx-status-endpoint.md](ocx-status-endpoint.md)), inferred from the launcher's `run` file and `launch.log` | Daemon gone. The endpoint answers 403, so no dot. |
| "Needs you" notifications | `needs_you` ticket field (`decision`, `merge`, `try-this`), written by the console and synced | The field isn't written anymore. Stone notifies on *any* post by someone else. |
| Decision prompts | Ticket comment and `design_input=confirm` | `ocx2 post --for` writes a text "question shape". Stone only spots its `For:` line. |
| Merge approval | `/ext/chat?merge_review=<uuid>`, opened in Safari | Nothing. |
| Try-this (verify a build) | `human_verify` ticket field | Nothing. |
| Agent console and session list | `/ext/agent`, SSE on :8443 | Nothing. Conversations come from forum posts in the clone. |

Every feature in the "before" column was a private contract with one daemon,
and the redesign removed all of them at once. The layer that replaces them
should be one that a client can rely on across `ocx` releases.

## What already works

`ocx2` run messages already fit. They are posts holding versioned JSON
(`"ocx": 1`) with a `kind` of `run`, `started`, `stop` or `ended`. Each one is
tagged `ocx-message` with its kind, so a client can find them through
`tagxref` without reading every post. They sync like any other post, and
`receipt` says who the server received each one from. That gives a durable,
lossless base. The requests below ask for that base to be completed and
frozen as a contract.

## Requirements

### R1. A published, versioned schema

- One document, kept with the `ocx` sources, defining every message kind and
  its fields, and the meaning of the `ocx` version number.
- Clients must ignore unknown kinds and unknown fields. Any change that breaks
  a client needs a new `ocx` version.
- Stone will read version 1 and show nothing for anything newer, rather than
  guess.

### R2. Run lifecycle, readable from the clone alone

- Every run must reach exactly one `ended` message. That includes a crash, a
  wall limit, a node restart and a lost node, written by whichever party
  notices first. Otherwise a client shows "running" forever.
- `ended` must carry an outcome from a fixed vocabulary (finished, stopped,
  limit, failed, lost, …) and a time.
- A run must state where it answers: its thread root or ticket, and the login
  it posts as (for example `run-af0dbe70`). That lets a client connect a
  thread's posts to the run behind them without asking the server.

### R3. Questions as messages, not as text

`ocx2 post --for` and `ocx2 questions` already model "something waits on a
user". But the question is prose in the post, and `questions` only runs on
the served repository. Stone has to compute the same answer from its clone,
while offline.

- A question must carry machine-readable fields: who it is for, the options,
  the stakes and the references. These can go in the post as a message or in
  tags on it. Readers keep the Markdown text.
- It must be clear when a question is **answered** or **withdrawn**, so a
  notification can clear itself and the badge count stays correct. The answer
  can be a reply that names the question it answers, or a message that closes
  it.
- What counts as waiting on a user must be defined exactly enough that Stone
  and `ocx2 questions` always agree. This is the role `needs_you` played: the
  phone must never show a card the server considers closed.

### R4. User actions that a client can write offline

Picking a question's option, approving a merge or a stage, marking a try-this
as tested, and stopping a run must each be a message a client writes into its
clone and syncs.

- They must be idempotent: syncing the same action twice, or acting after
  someone else already did, must change nothing.
- Authority is checked when the node acts, by the server's receipt and the
  sender's capabilities, as `stop` already is.
- Stone needs to know which user may perform which action, so it shows the
  button only to them. That needs a field or a rule, not trial and error.

### R5. Try-this and verify gates

A run that needs a person to verify something on a device must say so in a
message: what to try, on which build, and the possible verdicts. Recording
the verdict is a user action under R4. This replaces `human_verify` and is
how the maintainer closes phone testing (ticket f976c71210).

### R6. Optional live layer, with a fixed format

Working versus idle inside a turn changes too often to store in the
repository. One small read-only request for it is fine:

- per thread: `?thread=<root>` returning the run, `working` or `idle`, and
  since when
- answered for anyone who can read that thread. Today
  `/ext/ocx2-cgi/status?json=true` returns `"runs": []` to a viewer without
  setup.
- a fixed format covered by R1's versioning, not the tool's general output,
  which changes between `current` and `next`

Stone will treat this as decoration over R2. If it fails, the client falls
back to the run messages.

## Out of scope for now

- Running `ocx2` on the phone (WASM or otherwise). This stays in Milestone 5.
  With R1–R5, Stone only needs to read and write messages, which it can do in
  Swift.
- Push notifications (APNs). Stone raises local notifications after a sync.

## What Stone will do once this exists

- Read the run messages for the status line.
- Replace the `For:` check and the notify-on-any-post rule with R3.
- Render a question's options as buttons that write an R4 answer.
- Drop `/ext/ocx/status`, `needs_you`, `human_verify` and `/ext/chat`.
