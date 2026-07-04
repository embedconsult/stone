# Chronicle Readiness: contracts & boundaries Stone must honor

Status: **Readiness brief — for review**
Date: 2026-06-18
Relationship: this is the forward-compatibility contract for the **journaling**
plane of [vision-gateway.md](vision-gateway.md). Stone is **not** building
Chronicle; it must only avoid choices that would force a rewrite when Chronicle
lands.

## What Chronicle is (one paragraph)

Chronicle records a person's life streams into a Fossil repo: journal entries and
calendar events as **TechNotes** (one per event, keyed by EventKit UUID), health
and location data as **wiki pages** (`/health`, `/location`), photos/voice
transcripts as **attachment artifacts**. Server-side Crystal CGI helpers under
Fossil's `/ext` provide cross-stream temporal queries, export, and **semantic
search** over an `embedding` table of vector BLOBs in the repo's SQLite DB. The
vector store is being proven in Ollama-Codex first and adopted as-is.

## Contracts to FREEZE now (§6 — load-bearing)

These four are the plug-in points. Building against them now costs little; not
doing so forces rework later.

1. **technote-id = lowercase SHA1(EventKit UUID string)** — 40 hex chars.
   *(Amended 2026-06-18. The original "technote-id == EventKit UUID verbatim" is
   **unimplementable**: the enduring Fossil file format requires an E-card id to
   be a 40-char lowercase-hex string. An EventKit UUID is 36 chars, uppercase,
   hyphenated — not a legal id no matter what the CLI exposes. This is a
   published-standard constraint, not an `event.c` limitation, so there is no
   "hex vs UUID" decision to make — the standard decides.)*
   SHA1 of the UUID string emits exactly 40 hex chars and is a **pure function**,
   so idempotent addressing survives with no lookup table, no shared state, no
   sync problem — any device computes the id from the UUID directly. For
   human-auditable reverse linkage, **also record the raw UUID as a `T` card**
   (self-applied tag) on the technote; tags are artifacts and sync.
   ⇒ Stone's technote write path **must accept a caller-chosen technote-id** (the
   SHA1) and set a UUID tag.
2. **Wiki page names `/health` and `/location`** — long-lived, no date suffixes,
   receive **appended** records. ⇒ need wiki create/update *and* append, and
   tolerate large page histories.
3. **`embedding` table schema:**
   `technote_id TEXT PRIMARY KEY, model TEXT NOT NULL, vec BLOB NOT NULL`
   (768 × 4 = 3,072-byte float32 BLOBs to start; `model` is the compatibility
   key enforcing same-model discipline).
4. **`/ext` endpoints are the ONLY server-intelligence interface.** Stone never
   queries repo tables over the network directly — keeps the client thin, server
   logic in one-file readable Crystal CGI.

## The critical sync boundary: artifacts vs. tables

Fossil sync moves **artifacts** (and unversioned files if enabled). It does
**not** sync arbitrary SQLite tables. Consequences that drive the architecture:

- Chronicle **content** (technotes, wiki, attachments) syncs to the phone for
  free ⇒ **design Stone assuming the device clone is a complete, offline-usable
  copy of the content.**
- The `embedding` **vectors do not ride along** ⇒ **Stone must not assume search
  data exists on-device after a sync.**

## Where search happens (the boundary to respect)

**Plan of record: search is a SERVER responsibility.** The phone can't run
Ollama, and vectors are only meaningful with the exact model that produced them
(same-model discipline; the `embedding.model` column enforces/audits this).

Stone's search surface is therefore small:
- One HTTP call to a Crystal `/ext` endpoint, e.g.
  `GET /ext/search?q=...&k=5` → JSON `[{"id": technote_id, "score": 0.87}, ...]`.
- A results view that resolves each returned technote-id against the **local
  clone** (display works from synced content even though scoring was remote).
- **Graceful offline degradation:** hide/disable semantic search; browsing,
  writing, timeline all still work from the clone.

**Explicitly deferred — do NOT build:** on-device embedding (Core ML conversion
of an embedding model) and on-device vector scan. Known feasible upgrade path
(vectors as Fossil unversioned files + a one-file brute-force scan port) but it's
optimization before measured need and doubles the model-discipline surface.

## iOS-specific preparations

1. **Offline-first writes.** Create on phone, sync later. Fossil's append-only
   artifact model makes this safe. Queue sync via **BGTaskScheduler**; treat sync
   failure as **retryable, never data loss**.
2. **Repository growth discipline.** Attachments are content-addressed artifacts
   that sync forever; Fossil has **no shallow clone**. Photos/audio will dominate
   repo size. ⇒ record media at sane resolutions, **surface repo size to the
   user**, and leave room in the storage layout for a future "large media as
   unversioned files" policy.
3. **SQLite hygiene.** The clone is a SQLite DB: enable **WAL**, set an
   appropriate iOS **file-protection class**, and **never** touch the repo DB
   from two processes (app + extension) without Fossil's locking.

## Build now vs. know now

**Build now:** full Fossil *artifact* client — technotes with caller-chosen IDs,
wiki create/append, attachments (with a UI notion of "media belonging to an
entry"); offline-first sync; one HTTP search call + a results view resolving IDs
against the local clone.

**Know now:** sync moves artifacts not the embedding table; search stays remote
until measured need says otherwise; media size is the long-term repo risk; the
four §6 contracts are load-bearing.

## Impact on existing Stone design docs

- **Journaling plane** ([vision-gateway.md](vision-gateway.md) §2): the
  "technotes preferred" substrate choice is confirmed and now carries a hard
  requirement — **caller-chosen technote-id** (contract 1). Wiki append
  (contract 2) supports the `/health`/`/location` streams, which also serve the
  **logging/geolocation plane** (§4).
- **Read foundation** ([option-b-caching-browser.md](option-b-caching-browser.md)):
  unchanged; the "device clone is complete content" assumption reinforces the
  local-clone read path.
- **Agent-client auth** ([agent-client-scoping.md](agent-client-scoping.md)): the
  same login-cookie path feeds `/ext/search` and other `/ext` calls (contract 4).

## Open questions

- C1: **VERIFIED — caller-chosen technote-id is NOT reachable via stock Fossil.**
  On create, `event_cmd_commit` (`vendor/fossil-src-2.26/src/event.c:583`) takes
  no id parameter and always generates one: `zId = randomblob(20)` → a 40-char
  lowercase-hex id (`event.c:595`), written verbatim as the `E <etime> <id>` card
  and the `sym-<id>` tag. The `fossil wiki create --technote` CLI only sets the
  *DATETIME*, not the id. **The plumbing exists one layer down** —
  `event_commit_common(rid, zId, …)` already accepts a `zId` — but nothing
  exposes it. So honoring contract 1 needs **either** a small Fossil patch
  threading a `--technote-id` option into `event_cmd_commit`→`event_commit_common`
  (anti-drift: minimal, upstream-shaped), **or** a bridge path that assembles the
  event artifact directly with the chosen id. This is the **first artifact-client
  gap** and a prerequisite for the journaling plane.
  - C1a: **Id format — RESOLVED by the file-format standard, not a decision.**
    E-card ids must be 40-char lowercase hex, so the id Stone passes is
    `SHA1(EventKit UUID)` (see amended contract 1), with the raw UUID recorded as
    a `T` card for reverse linkage. This removes the earlier "hex vs UUID"
    question entirely.
  - C1b: **Chosen approach — the patch (not the bridge).** `event_commit_common`
    already accepts `zId`; the fix is ~10 lines of option plumbing in
    `event_cmd_commit` to thread a new `--technote-id` (exposing existing,
    reviewed logic — no new logic). Submit **upstream to Fossil** as an explicit
    goal: if it lands, the write path carries **zero** vendored debt; until then
    it's a trivially readable diff against a slow-moving file. **Reject the
    bridge** for the production path: assembling the E-card artifact in
    Swift/Crystal is easy, but *injecting* a hand-built artifact needs unstable
    test commands or speaking the xfer protocol — that injection half is the
    high-debt trap. (Assembly-in-code is worth doing once as a teaching artifact
    for the docs, not as the write path.)
- C2: WAL + file-protection class choice given the in-process Fossil server and
  any future extension (Share/Widgets) touching the same DB.
- C3: Repo-size UX — where/when to surface size and the media-resolution policy.
