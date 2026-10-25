# Waking a sync with Fossil's /chat-poll

Stone used to learn about new posts only at its Automatic Sync interval. OCX's
layers design (ollama wiki "Layers design", section 4) wakes every listener
with Fossil's own chat long-poll instead. `ocx` called this part stable on
2026-10-25. This page records what Stone relies on, what it does, and what a
server needs for it to work.

## What Fossil does

The checks are scripts/linux-chat-poll-test.sh, run against Fossil 2.27 on
Linux on 2026-10-25.

- With the repository setting `chat-timeline-user` set (to any name, such as
  `TIMELINE`), every timeline event adds a row to the chat table. That covers
  check-ins, forum posts, ticket changes, tags and wiki edits, whether written
  on the server or arriving by push. One push can add several rows.
- `GET <repo>/chat-poll?name=N` answers with every row newer than `N`. If
  there's none, it waits until one is added or the server's
  `chat-poll-timeout` passes (Fossil's default is 420 s), then answers
  `{"msgs":[]}`.
- `name=-1` answers at once with the newest row alone. That gives a starting
  point without the history.
- A request naming an older row answers at once with what it missed, so
  nothing is lost between requests.
- The request needs a same-origin Referer, such as `<repo>/chat`. Without one,
  Fossil answers an HTML error page, not JSON.
- The login needs the chat capability `C`. Without it, or with an expired
  cookie, Fossil answers **200** with one row holding `"isError": true`, not a
  401.
- The chat table is made by the first `/chat-poll` that has a Referer. Events
  before that add no row.

## What Stone does

These are `RemoteWake` and `ForegroundSync`, both in
ios/Stone/Services/RemoteWake.swift.

- While the app is in the foreground and Automatic Sync is on (and Low Power
  Mode isn't holding it back), Stone keeps one request waiting per repository
  with a remote and a saved password. StoneApp starts this when the app
  becomes active and stops it when the app goes to the background, whatever
  screen is showing.
- It starts from `name=-1`. When that answers at once, the row was already
  there and wakes nothing. When it waits, the chat table was empty and the
  row is new, so it wakes a sync.
- Every later answer holding rows syncs that repository, as Sync does, then
  raises the same notifications. The next request names the newest row seen.
- At most one wake sync per repository every 30 seconds. Events in between
  are taken by the next sync.
- An `isError` answer logs in again once. A second one means the login lacks
  `C` or chat is off, and that repository is left to the timer until the app
  next becomes active.
- A network failure backs off: 15 s more each time, up to 5 minutes. The next
  request then names the same row, so nothing recorded meanwhile is missed.
- Automatic Sync's timer keeps running as the fallback, with the same start
  and stop.

## What a server needs

- `chat-timeline-user` set on each repository Stone follows. On
  ollama.openbeagle.org the maintainer sets this as each repository switches
  to the layers design. Until then, `/chat-poll` wakes only for real chat
  messages.
- `C` for the phone's login. As of 2026-10-25, `stone` has it on the stone
  repository.
- A server `chat-poll-timeout` below Stone's request timeout of 480 s. The
  layers design suggests 60 s.

## Not yet

- Background wakes: iOS suspends the app's requests in the background, where
  Stone's BGTaskScheduler sync still runs.
- The tag that records which session a post was given to. It comes in the
  layers design's step 3.
