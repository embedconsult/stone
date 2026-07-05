# Chronicle Readiness: contracts & boundaries Stone must honor

Status: **Journaling-plane design, implemented in Stone.**
Date: 2026-06-18 (unified 2026-06-18)
Relationship: **Chronicle names the journal repository, not an application.**
There is no separate Chronicle app — Stone is the single iPhone app, and this is
the design for the **journaling plane** of [vision-gateway.md](vision-gateway.md),
implemented directly in Stone. All four §6 contracts derive from Fossil's design
and the phone's constraints (identical whether or not the app is split), so
nothing below changes under unification; only the "future app plugs in later"
framing is retired.

## What Chronicle is (one paragraph)

Chronicle (the journal **repository**) records a person's life streams into a
Fossil repo: journal entries and
calendar events as **TechNotes** (one per event, keyed by EventKit UUID), health
and location data as **wiki pages** (`/health`, `/location`), photos/voice
transcripts as **attachment artifacts**. Server-side Crystal CGI helpers under
Fossil's `/ext` provide cross-stream temporal queries, export, and **semantic
search** over an `fx_embedding` table of vector BLOBs in the repo's SQLite DB. The
vector store is being proven in Ollama-Codex first and adopted as-is.

## Contracts to FREEZE now (§6 — load-bearing)

These four are the plug-in points. Building against them now costs little; not
doing so forces rework later.

1. **technote-id = lowercase SHA1(EventKit UUID string)** — 40 hex chars.
   *(Amended 2026-06-18. The original "technote-id == EventKit UUID verbatim" is
   **unimplementable**: the enduring Fossil file format requires an E-card id to
   be a 40-char lowercase-hex string (verified: `www/fileformat.wiki:499`, "The
   technote-id must be a 40-character lower-case hexadecimal string"). An EventKit
   UUID is 36 chars, uppercase,
   hyphenated — not a legal id no matter what the CLI exposes. This is a
   published-standard constraint, not an `event.c` limitation, so there is no
   "hex vs UUID" decision to make — the standard decides.)*
   SHA1 of the UUID string emits exactly 40 hex chars and is a **pure function**,
   so idempotent addressing survives with no lookup table, no shared state, no
   sync problem — any device computes the id from the UUID directly. *(SHA1 is
   used here purely as a deterministic 40-hex **name derivation** from unique,
   trusted inputs — not for collision resistance — so its cryptographic
   deprecation is irrelevant and its output length is exactly what the E-card
   standard demands.)* For human-auditable reverse linkage, **also record the raw
   UUID as a self-applied tag named `uuid-<raw-uuid>`** (a `T` card); tags are
   artifacts and sync, and exact tag-name lookup via `tagxref` is the cheap
   indexed path in every stock binary — prefer a hyphenated tag *name* over a
   `name:value` hybrid.
   ⇒ Stone's technote write path **must accept a caller-chosen technote-id** (the
   SHA1) and set the `uuid-` tag.
2. **Wiki page names `/health` and `/location`** — long-lived, no date suffixes,
   receive **appended** records. ⇒ need wiki create/update *and* append, and
   tolerate large page histories.
   *(Amended 2026-06-18 — idempotent append. Wiki append is not naturally
   idempotent: a writer killed mid-sync, or retrying after an ambiguous failure,
   would append the same health/location records twice, and nothing in the append
   model prevents it — unlike contract 1's content-addressed ids. Rule: **every
   appended record carries its source timestamp** (the HealthKit sample UUID where
   one exists), and the writer appends only records **strictly newer than the
   newest timestamp already on the page.** The page itself is the high-water mark,
   so the writer stays **stateless** — the same idempotency-by-construction that
   contract 1 gets from `SHA1(UUID)`.)*
3. **`fx_embedding` table schema:**
   `technote_id TEXT PRIMARY KEY, model TEXT NOT NULL, vec BLOB NOT NULL`
   (768 × 4 = 3,072-byte float32 BLOBs to start; `model` is the compatibility
   key enforcing same-model discipline).
   *(Amended 2026-06-18 — the `fx_` prefix is load-bearing, not cosmetic. A stock
   `fossil rebuild` DROPs every repository table outside Fossil's whitelist except
   those matching `GLOB 'fx_*'` (verified: `src/rebuild.c:407`,
   `AND name NOT GLOB 'fx_*'`). A table named `embedding` would be silently
   destroyed on the first server-side rebuild; `fx_embedding` survives. The final
   name must match whatever `fx_`-prefixed name Ollama-Codex lands on, since
   Chronicle adopts that vector store as-is. This amendment costs Stone **zero
   code** — by contract 4 Stone only ever calls `/ext/search`, never the table —
   which is contract 4 already proving its worth.)*
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
(same-model discipline; the `fx_embedding.model` column enforces/audits this).

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
**Unfreeze trigger:** *measured* search latency against the remote `/ext/search`
call, or demonstrated offline-search demand. Absent that evidence, do not build.

## iOS-specific preparations

1. **Offline-first writes.** Create on phone, sync later. Fossil's append-only
   artifact model makes this safe. Queue sync via **BGTaskScheduler**; treat sync
   failure as **retryable, never data loss**.
2. **Repository growth discipline.** Attachments are content-addressed artifacts
   that sync forever; Fossil has **no shallow clone**. Photos/audio will dominate
   repo size. ⇒ record media at sane resolutions, **surface repo size to the
   user**, and leave room in the storage layout for a future "large media as
   unversioned files" policy. **Unfreeze trigger:** the contract-3 repo-size
   surface showing real journal repositories crossing a storage pain threshold
   on device. Absent that evidence, keep media as ordinary content-addressed
   artifacts.
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

## Patch scope: `--technote-id` (C1 implementation)

Concrete, ~10-line change exposing already-reviewed logic. Call chain today:
`wiki_cmd` (`src/wiki.c`) parses `--technote*` options and computes `rid`, then
calls `event_cmd_commit(zMETime, rid, …)` (`wiki.c:2486`) →
`event_cmd_commit` (`src/event.c:583`) which, when `rid==0`, generates
`zId = randomblob(20)` (`event.c:595`) → `event_commit_common(rid, zId, …)`
(already accepts `zId`).

Change:
1. `src/wiki.c` (~`2416`, beside the other `find_option` calls): add
   `const char *zTNId = find_option("technote-id", NULL, 1);` and pass it into
   `event_cmd_commit`.
2. `src/event.c` `event_cmd_commit`: add a `const char *zGivenId` param; when
   `rid==0 && zGivenId` use it instead of `randomblob(20)`. **Validate** it is a
   40-char lowercase-hex string (`fossil_fatal` otherwise) — enforces the E-card
   format standard so contract 1's `SHA1(UUID)` is the intended input.
3. `event_commit_common` — unchanged.
4. Also allow a self-applied `T` card for the raw-UUID tag (contract 1); if the
   existing `--technote-tags` path suffices, no extra code — just pass
   `uuid-<raw>` as a tag **name** (hyphenated name, not a `name:value` hybrid, so
   it resolves via the indexed `tagxref` exact-name path in stock binaries).

**Carry + upstream:** land as a hunk in `scripts/fossil-inprocess.patch` (same
mechanism as the SQLITE_MISUSE once-guard) so it regenerates with the vendored
tree. **Submit upstream to the Fossil project as an explicit goal** — it's a
clean, general feature (deterministic technote ids) worth offering; if accepted,
the write path carries zero vendored debt.

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
  any future extension (Share/Widgets) touching the same DB. **The interaction to
  watch:** `NSFileProtectionComplete` makes the repo DB unreadable while the
  device is locked — which is exactly when a BGTaskScheduler sync tends to fire,
  so it would silently break offline-first sync.
  **`NSFileProtectionCompleteUntilFirstUserAuthentication`** keeps sync alive
  after first unlock without giving up protection, and is the likely choice. A
  future Share-extension additionally forces the DB into an **app-group
  container**, where Fossil's POSIX locking needs verifying (spike-shaped).
- C3: Repo-size UX — where/when to surface size and the media-resolution policy.
