# Vision: Stone as a Gateway (read · chronicle · control)

Status: **Vision / direction — for review**
Date: 2026-06-18 (unification amendment 2026-07-04; plane renumber 2026-07-04)
Sources: ticket #552b1261 (maintainer note 2026-06-18); maintainer (2026-06-18,
2026-07-04 unification: no separate Chronicle app — Stone is the single app,
"Chronicle" names the journal repository; 2026-07-04 adjudication: logging folds
into Chronicle as a write mode)

Stone is more than a Fossil browser. The long-term aim is a **gateway**: the
phone as a capture + control surface backed by Fossil's content-addressed,
sync-able substrate everywhere — offline-first. Three planes, loosely coupled,
sharing one auth + sync foundation.

## The planes

### 1. Cached read (foundation)
Option B caching proxy — browse anything, offline-capable. See
[option-b-caching-browser.md](option-b-caching-browser.md). Everything else
builds on this read foundation.

### 2. Embedded offline-first write = CHRONICLE  ← nearer, lower-risk pillar
Plays directly to Stone's **existing** strength (in-process Fossil + clone/sync):
capture *anywhere*, write it to the local clone, `fossil sync` on
reconnect — **no server round-trip to capture a thought.**

**This plane IS Chronicle.** "Chronicle" is the name of the **journal
repository**, not a separate application — Stone is the single app, and
[chronicle-readiness.md](chronicle-readiness.md) is the detailed design for this
plane, implemented directly in Stone.

**Two write modes** (adjudicated 2026-07-04 — the former "logging/geolocation"
plane 4 folds in here; the split is *who writes*, not separate planes — same
repo, same contracts, same role):
- **authored** — human-written entries (technotes preferred / wiki / forum);
  idempotent via contract 1; needs **UI**.
- **captured** — machine streams (`/health`, `/location`, and other structured
  location-tagged logs); idempotent via contract 2; needs **background
  scheduling**. This is the "tie geolocation into a Fossil database" ambition
  (maintainer, 2026-06-18), realized as ordinary Fossil artifacts.

Fossil-native substrate (no bespoke storage): **technotes** (timestamped
timeline journal — most on-brand, the default), **wiki** (long-form + the
captured `/health`/`/location` pages), **forum** (conversational).

Shape: a **capture UI + sync-outbox** over what Stone already does. This is the
recommended *next* build target after the Option B read foundation, ahead of the
full agent-control plane, because it reuses existing clone/sync and has no remote
live-protocol dependency.

Its four load-bearing contracts — **defined in
[chronicle-readiness.md](chronicle-readiness.md), which owns them; do not
restate here:**
1. Caller-chosen technote-ids.
2. Idempotent wiki append to `/health` + `/location`.
3. The `fx_`-prefixed vector table.
4. `/ext` as the only server-intelligence interface (search is remote).

**Build now (this plane's roadmap):** full Fossil *artifact* client — technotes
with caller-chosen IDs, wiki create/append, attachments — plus the capture UI +
sync-outbox. **Know now (freeze, don't build):** contracts 3 and 4 (the vector
table and the remote-search boundary), so the semantic layer lands later without
rework. See chronicle-readiness.md "Build now vs. know now" for the split.

### 3. Remote live control = ANYWHERE CODING
The phone as cockpit for a **remote** agent (daemon + models stay server-side).
This is the agent-client layer scoped in
[agent-client-scoping.md](agent-client-scoping.md): login-cookie auth, JSON
session endpoints, `:8443` SSE live events, forum-CSRF posting as the human.

*(The former plane 4, "logging incl. geolocation into a Fossil database," is now
the **captured** write mode of the Chronicle plane above — same repo, same
contracts, same `.journal` role. Privacy/consent for location data remains an
open question; see below.)*

## The bridge: note → ticket → session
A journal entry captured offline can, on sync, become a **ticket / task prompt**,
which can seed an agent **session** — note → ticket → session, all Fossil-native.
This is what ties the Chronicle pillar (plane 2) to the anywhere-coding pillar
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

## Conflicts surfaced by unification (adjudicated 2026-07-04)

The 2026-07-04 fold-in exposed two boundary questions; the maintainer resolved
both:

- **Plane 2 vs. plane 4 collapse → one Chronicle plane, two write modes.** The
  2/4 split was drawn along *who writes*, but both write the same repo through
  the same contracts under the same role — a distinction of write paths, not
  planes. Resolved: plane 4 folds into plane 2 as the **captured** write mode
  (`authored` = human, `captured` = machine). Planes renumbered to three.
- **Sequencing vs. role gating → keep one `.journal` role; sources stage
  independently.** Which capture sources are live is **per-source state within
  the role**, not part of the role itself. iOS forces this regardless: every
  source (EventKit / HealthKit / CoreLocation / photos) has its own
  permission prompt, grantable and revocable independently in Settings, so
  Stone must already handle partial capture capability. Per-source staging is
  therefore free — each observer stays one file, one responsibility, enabled
  independently — and sequencing steps remain separable (same role, different
  observers landing at different milestones).

## Per-repository role (design proposal — not yet built)

The planes are not uniform across repositories: a code repo wants the
agent-client control plane; the **Chronicle** journal repo wants capture
observers and unattended background writes. Rather than special-casing by name,
each repository carries **one visible role flag** that gates plane behavior.

**Data model:** a `Role` enum added to `struct Repo` (Codable), persisted in the
existing `index.json` — so the role is the single durable flag that survives
launches, sits next to `remoteURL`, and is the *only* thing behavior keys on.
`Repo` decodes `role` **with a default of `.code`** when the key is absent, so
existing `index.json` files need no migration step.

```swift
enum Role: String, Codable {
    case code      // default — agent-client / anywhere-coding target
    case journal   // Chronicle: authored + captured write modes
}

// In Repo.init(from:): decode role with a default, so pre-role index
// entries load as .code without migration.
role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .code
```

**Hard rule:** behavior keys on `repo.role`, **never** on a
repository-name string match. No scattered `if repo.name == "chronicle"`; one
flag, checked in one place per capability.

**What `.journal` gates** (all off for `.code`):
- **Capture observers** — EventKit / HealthKit / CoreLocation / photo picker
  feeding the contract-1 technotes and contract-2 `/health` + `/location` pages.
  The **role** gates the whole capability *class*; **which sources are live is
  per-source state within the role**, not part of the role. Each source has its
  own iOS permission (independently grantable/revocable in Settings), so Stone
  handles partial capture capability regardless — each observer is one file, one
  responsibility, enabled independently, and can land at a different milestone.
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
2. **Chronicle authored capture + sync-outbox** (plane 2, authored mode) — lower
   risk, high daily value.
3. note → ticket bridge.
4. Agent-client control plane (plane 3) — per agent-client-scoping.md.
5. **Chronicle captured mode** (plane 2, captured: geolocation/health/logging),
   with privacy controls — same role, staged per-source after the authored UI.

## Open questions
- V1: Journaling default substrate — technotes (recommended) vs let the user
  pick per entry?
- V2: Sync-outbox conflict handling when an offline entry meets remote changes.
- V3: Captured mode (geolocation/health/logging) — capture cadence, on-device
  privacy controls, and consent; what exactly becomes a Fossil artifact vs.
  stays local.
- V4: note → ticket mapping — automatic on sync, or an explicit "promote to
  ticket" action?
