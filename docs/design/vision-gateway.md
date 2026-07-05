# Vision: Stone as a Gateway (read · journal · control · log)

Status: **Vision / direction — for review**
Date: 2026-06-18 (unification amendment 2026-07-04)
Sources: ticket #552b1261 (maintainer note 2026-06-18); maintainer (2026-06-18,
2026-07-04 unification: no separate Chronicle app — Stone is the single app,
"Chronicle" names the journal repository)

Stone is more than a Fossil browser. The long-term aim is a **gateway**: the
phone as a capture + control surface backed by Fossil's content-addressed,
sync-able substrate everywhere — offline-first. Four planes, loosely coupled,
sharing one auth + sync foundation.

## The planes

### 1. Cached read (foundation)
Option B caching proxy — browse anything, offline-capable. See
[option-b-caching-browser.md](option-b-caching-browser.md). Everything else
builds on this read foundation.

### 2. Embedded offline-first write = JOURNALING  ← nearer, lower-risk pillar
Plays directly to Stone's **existing** strength (in-process Fossil + clone/sync):
compose an entry *anywhere*, write it to the local clone, `fossil sync` on
reconnect — **no server round-trip to capture a thought.**

Fossil-native substrate (no bespoke storage):
- **technotes** — timestamped timeline journal; most on-brand, the default.
- **wiki** — long-form entries.
- **forum** — conversational.

Shape: a **capture UI + sync-outbox** over what Stone already does. This is the
recommended *next* build target after the Option B read foundation, ahead of the
full agent-control plane, because it reuses existing clone/sync and has no remote
live-protocol dependency.

**This plane IS Chronicle.** "Chronicle" is the name of the **journal
repository**, not a separate application — Stone is the single app, and
[chronicle-readiness.md](chronicle-readiness.md) is the detailed design for this
plane, implemented directly in Stone. Its four load-bearing contracts (all
derived from Fossil's format + the phone's constraints):
- **Caller-chosen technote-ids** = `SHA1(EventKit UUID)` (40-char lowercase hex,
  the format-required shape; verbatim UUID is illegal), with the raw UUID kept as
  a `uuid-<raw>` tag for reverse lookup.
- **Wiki append** to the long-lived `/health` and `/location` pages, done
  **idempotently** (each record carries its source timestamp; the page is the
  high-water mark; the writer stays stateless).
- **`fx_embedding` table** (the `fx_` prefix is load-bearing — a stock
  `fossil rebuild` drops any non-whitelisted table not matching `fx_*`).
- **`/ext` is the only server-intelligence interface**; sync moves artifacts,
  **not** the `fx_embedding` vectors, so **search is a remote `/ext/search`
  call** resolved against the local clone.

**Build now (this plane's roadmap):** full Fossil *artifact* client — technotes
with caller-chosen IDs, wiki create/append, attachments — plus the capture UI +
sync-outbox. **Know now (freeze, don't build):** the `fx_embedding` schema and
the remote-search boundary, so the semantic layer lands later without rework. See
chronicle-readiness.md "Build now vs. know now" for the split.

### 3. Remote live control = ANYWHERE CODING
The phone as cockpit for a **remote** agent (daemon + models stay server-side).
This is the agent-client layer scoped in
[agent-client-scoping.md](agent-client-scoping.md): login-cookie auth, JSON
session endpoints, `:8443` SSE live events, forum-CSRF posting as the human.

### 4. Logging — incl. geolocation into a Fossil database
Maintainer direction (2026-06-18): "integrate a lot of logging features,
including tying geolocation into a fossil database." Structured / location-tagged
log capture, recorded as **Fossil artifacts** (consistent with the journaling
substrate), offline-first then synced. Conceptually adjacent to plane 2 — a
journal of *machine-captured* events rather than human-authored entries. Chronicle
already models health/location as the long-lived wiki pages `/health` and
`/location` ([chronicle-readiness.md](chronicle-readiness.md) contract 2), so this
plane and Chronicle share substrate. (Privacy/consent for location data is an
explicit open question; see below.)

## The bridge: note → ticket → session
A journal entry captured offline can, on sync, become a **ticket / task prompt**,
which can seed an agent **session** — note → ticket → session, all Fossil-native.
This is what ties the journaling pillar (plane 2) to the anywhere-coding pillar
(plane 3): capture a thought offline, and it can later drive remote work.

## Shared foundation (don't duplicate per plane)
- **Auth:** one Fossil login-cookie path (via `<repo>/login` from the Keychain
  credential), forwarded to all remote calls. Native client ⇒ no browser
  CSP/CORS.
- **Sync:** clone + `fossil sync` (already present) is the transport for both
  journaling write-back and pulling read/agent state.
- **Substrate:** Fossil artifacts (technote/wiki/forum/ticket) — prefer these
  over bespoke local stores so everything is content-addressed and syncs for
  free.

## Conflicts surfaced by unification (flagged, not resolved)

The 2026-07-04 fold-in exposed two boundary questions worth a maintainer call
rather than a silent choice here:

- **Plane 2 vs. plane 4 collapse into one repo/role.** This doc framed plane 2
  as *human-authored* journaling and plane 4 as *machine-captured* logging — but
  Chronicle's contract-2 `/health` and `/location` are machine-captured streams
  that live in the **journal repository**, and the proposed `.journal` role is
  what gates CoreLocation/HealthKit capture. So "logging/geolocation" is not a
  separate plane so much as the *automated* half of Chronicle. Open question:
  keep plane 4 as a distinct plane for narrative clarity, or explicitly fold it
  into plane 2 as "Chronicle: attended + unattended capture"?
- **Sequencing vs. role gating.** The suggested sequencing lists journaling
  (step 2) before geolocation/logging (step 5), but the `.journal` role bundles
  both capture kinds under one flag. If they ship on one role, the capture
  observers can't be sequenced apart cleanly — step 2 and step 5 partially merge.

Both are left open deliberately; resolving them changes plane numbering and the
role's gated-capability list.

## Per-repository role (design proposal — not yet built)

The planes are not uniform across repositories: a code repo wants the
agent-client control plane; the **Chronicle** journal repo wants capture
observers and unattended background writes. Rather than special-casing by name,
each repository carries **one visible role flag** that gates plane behavior.

**Data model:** a `Role` enum added to `struct Repo` (Codable), persisted in the
existing `index.json` — so the role is the single durable flag that survives
launches, sits next to `remoteURL`, and is the *only* thing behavior keys on.

```swift
enum Role: String, Codable {
    case code      // default — agent-client / anywhere-coding target
    case journal   // Chronicle: capture + logging plane
}
```

**Hard rule:** behavior keys on `repo.role`, **never** on a
repository-name string match. No scattered `if repo.name == "chronicle"`; one
flag, checked in one place per capability.

**What `.journal` gates** (all off for `.code`):
- **Capture observers** — EventKit / HealthKit / CoreLocation / photo picker
  feeding the contract-1 technotes and contract-2 `/health` + `/location` pages.
- **Unattended background writes** — BGTaskScheduler capture + sync-outbox.
- **Stricter file protection** — the C2 discipline (offline-first-safe
  protection class so background writes work while locked).
- **Its own sync cadence** — journals sync on a capture-driven schedule, not the
  interactive code-repo cadence.
- **Repo-size surface** — the contract-3 storage-pain readout (journals are the
  media-growth risk; code repos are not).

`.code` is the default so existing repositories and the agent-client plane are
unaffected. This is a **proposal to freeze the shape**, not a build order — no
capture machinery is built until the journaling plane is scheduled.

## Suggested sequencing (vision-level, not committed)
1. Option B read foundation (in progress / designed).
2. **Journaling capture + sync-outbox** (plane 2) — lower risk, high daily value.
3. note → ticket bridge.
4. Agent-client control plane (plane 3) — per agent-client-scoping.md.
5. Geolocation/logging-into-Fossil (plane 4), with privacy controls.

## Open questions
- V1: Journaling default substrate — technotes (recommended) vs let the user
  pick per entry?
- V2: Sync-outbox conflict handling when an offline entry meets remote changes.
- V3: Logging/geolocation — capture cadence, on-device privacy controls, and
  consent; what exactly becomes a Fossil artifact vs. stays local.
- V4: note → ticket mapping — automatic on sync, or an explicit "promote to
  ticket" action?
