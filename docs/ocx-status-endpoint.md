# OCX agent status endpoint

Stone's conversation view shows, under the title of a forum thread, whether
the agent answering it is working, idle or stopped. Only OCX on the server
knows that, so OCX publishes it here. Chosen by the maintainer on the
conversations thread (forum post 9c88a45eda).

## Request

    GET <repo>/ext/ocx/status?thread=<root>

- `<repo>` is the repository's base URL, the same one Stone syncs with,
  e.g. `https://ollama.openbeagle.org/stone`.
- `<root>` is the full artifact hash of the thread's first post (a forum
  post's G card).
- Read-only. Stone sends the Fossil login cookie when the repo has a saved
  password and nothing otherwise, so the endpoint should answer for anyone
  who can read the thread.
- Stone asks every 15 seconds while that conversation is on screen, and never
  in the background.

## Response

`200`, `Content-Type: application/json`:

    {"login":"opus","state":"working","since":"2026-09-24T03:00:21Z","last_post":"<hash>"}

| field       | required | meaning |
|-------------|----------|---------|
| `login`     | yes      | the agent's Fossil login on this thread |
| `state`     | yes      | `working`, `idle` or `stopped` (anything else is ignored) |
| `since`     | no       | when it entered `state`, ISO 8601 UTC |
| `last_post` | no       | hash of the agent's latest post on the thread |

When no agent is bound to the thread, answer `404`. Stone shows nothing for a
404, a non-JSON body or an unknown state, so an older server simply has no
indicator.

## Deriving the state from what OCX already records

Each run's workspace holds `run` (`{"pid", "started", "record", "login",
"runner"}`) and `launch.log`, where the launcher writes `idle` about once a
minute while it waits and `answered` when a turn ends. While a turn runs,
nothing is written.

- **stopped**: no `run` file for the thread, or its `pid` is not alive.
  `since` is the log's last line time.
- **idle**: alive, and the log's last line is `idle` or `answered`, less than
  about 90 seconds old. `since` is the time of the first `idle` after the
  last `answered` (or after start).
- **working**: alive, and the log has been quiet for more than about 90
  seconds. `since` is the last line's time.

Inferring "working" from silence works today but is fragile. Having the
launcher write a `working` line when a turn starts would make it exact.

## Stone side

- `ios/Stone/Models/AgentStatus.swift`: decoding and the label ("opus is
  working", "opus idle since 22:47", "opus stopped at 21:10").
- `ios/Stone/Services/AgentStatusClient.swift`: the request.
- `ios/Stone/Views/ConversationView.swift`: the 15-second poll and the dot
  (green working, yellow idle, grey stopped) under the title.
