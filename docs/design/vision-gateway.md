# Vision: Stone as a Gateway (read · journal · control · log)

Status: **Vision / direction — for review**
Date: 2026-06-18
Sources: ticket #552b1261 (maintainer note 2026-06-18); maintainer (2026-06-18)

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

> **Forward-compat:** this plane is where **Chronicle** (journaling + semantic
> search) later plugs in. See [chronicle-readiness.md](chronicle-readiness.md)
> for the contracts to freeze now — chiefly **caller-chosen technote-ids**
> (`technote-id == EventKit UUID`), wiki append to `/health`/`/location`, and the
> "sync moves artifacts, not the embedding table; search is a remote `/ext` call"
> boundary.

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
