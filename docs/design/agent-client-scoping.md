# Scoping: Agent-Aware Optimized Client (ticket #552b1261)

Status: **Scoping — for review**
Date: 2026-06-17
Parent design: [option-b-caching-browser.md](option-b-caching-browser.md) §10

This breaks the ticket's three named gaps into concrete, reviewable units of
work against the current codebase. No implementation yet.

Current state (what exists today):
- `Repo` (`ios/Stone/Models/Repo.swift`) — pure data: `id`, `name`, `fileName`,
  `remoteURL`. No notion of a user identity or session.
- `CredentialStore` (`…/Services/CredentialStore.swift`) — Keychain, keyed by
  repo UUID, stores one *password* per repo. No username, no cookie.
- `FossilEngine` (`…/Services/FossilEngine.swift`) — runs `fossil` commands and
  the loopback server via the C bridge. No HTTP-client capability of its own.
- `RepoStore` — clone/sync/rename/delete; `urlWithPassword()` injects the
  password into the remote URL's userinfo for Fossil's own sync.
- UI is browse/clone/sync only (`RepoListView`, `RepoDetailView`,
  `RepoWebView`); no Sessions/Thread/composer views.

## Gap 1 — Login + cookie-forward auth

**Goal:** obtain a Fossil login cookie for a remote and forward it on agent
requests (JSON endpoints, `/forume2`, `session_live_url` mint).

**What Fossil's login actually is (to verify before building):** Fossil's `/login`
sets a `fossil-<projcode>` cookie tied to the project. We need to confirm the
exact login form fields and cookie name against a live `ollama.openbeagle.org`
repo (anonymous capabilities, whether a captcha/`anoncap` flow is involved, and
whether the JSON endpoints accept the cookie vs. a separate token).

**New pieces:**
- A `username` alongside the existing per-repo password. Options: add a
  `username: String?` to `Repo` (it's not secret) **or** store a
  `user:password` pair in `CredentialStore`. Leaning: `username` on `Repo`
  (non-secret, visible in metadata), password stays in Keychain. Decision
  needed.
- A `RemoteSession` service: performs `POST /login`, captures the
  `Set-Cookie`, holds it in memory (and optionally Keychain for reuse), exposes
  `authorizedRequest(for: URL) -> URLRequest` that attaches the cookie. Built on
  `URLSession` (native HTTPS — *not* the Fossil C path; this is client traffic,
  cleanly separate from `FossilEngine`).
- CA trust: `URLSession` uses the iOS system trust store, so unlike the Fossil C
  core it does **not** need the bundled `cacert.pem`. (Confirm the host's chain
  validates against system roots.)

**Risks / unknowns:** cookie lifetime + refresh-on-401; whether `session_live_url`
needs the cookie or only the minted HMAC token; CSRF token on the login form.

**Estimated surface:** ~1 new service file + a small `Repo`/credential change.
No C-bridge changes.

## Gap 2 — Native Sessions view + SSE consumer + reply composer

**Goal:** a native mobile UI to list sessions/threads, watch a turn live, and
post a reply as the human.

**Sub-units:**
1. **JSON models + fetch.** Decode the agent endpoints into Swift `Codable`
   models. Known contracts (maintainer, 2026-06-18):
   - `GET <repo>/ext/agent?session_posts=<root>` →
     `{ ok, posts: [{ hash, user, mtime, role, html }] }`
   - `GET <repo>/ext/agent?session_live_url=<root>` → the signed `:8443` SSE URL
     (mints the per-project HMAC token).
   Still want a captured live sample of turn-status JSON to confirm shape.
2. **Sessions/Thread SwiftUI view.** List threads → thread detail showing posts;
   read-only first.
3. **SSE consumer.** Connect to the `:8443` live-events stream (URL minted by
   `session_live_url`, which carries the per-project HMAC token). SSE = a
   long-lived `text/event-stream` `URLSession` data task parsing `event:`/`data:`
   frames; surface `turn_started` / `turn_heartbeat` / **`turn_finished`** as live
   status. Needs lifecycle handling (connect on view appear, tear down on
   disappear, reconnect/backoff).
4. **Reply composer (the Fossil forum CSRF dance).** Posting as the human is
   **not** a single POST — it's Fossil's forum reply flow:
   1. `GET <repo>/forumedit?fpid=<H>&reply` (authenticated with the login cookie).
   2. Scrape `name="csrf" value=".."` out of the returned reply editor HTML.
   3. `POST <repo>/forume2` with the `csrf` token + a `Referer` header (preview,
      then submit).
   Reference implementation: **`ollama-codex src/forum_writer.cr`**. Requires the
   login cookie **and forum-reply capability** on that repo (cap 3/4, or s/a). A
   repo not provisioned with forum caps/enable fails with **"no csrf token in
   reply editor"** (observed live on `blabl`, 2026-06-17). **Stone must surface
   auth/cap failures distinctly** (e.g. "not permitted to post on this repo")
   rather than as a generic error. Write action → confirm before send (consistent
   with guarding anything that leaves the device).

**Risks / unknowns:** exact JSON schemas; SSE token lifetime; turn-status polling
vs SSE overlap; detecting the no-csrf cap-failure cleanly vs other HTML errors.

**Estimated surface:** several new files (models, 2–3 views, SSE client). Largest
of the three gaps.

## Gap 3 — Native vs WKWebView for agent views

**Decision, not code.** Two viable paths:

| Approach        | Pros                                              | Cons                                            |
|-----------------|---------------------------------------------------|-------------------------------------------------|
| **Native**      | Best mobile UX; true "optimized client"; offline-cacheable JSON; no CSP/CORS | Most work; must track agent JSON schema changes |
| **WKWebView**   | Fastest to ship; reuses server HTML; low drift    | Opaque HTML; need cookie injection; the sluggish/flaky issues that motivated Option B |

**Recommendation:** **native for the live agent surface** (Sessions/Thread/SSE/
composer) — that is precisely the ticket's value proposition and avoids the
WKWebView pain Option B was created to fix. Keep WKWebView for general
Fossil browse/read (working-copy and remote-cached HTML pages). This matches the
client/server split in §10.

## Proposed build order

1. **Gap 1** (login + cookie-forward) — unblocks everything; smallest surface.
2. **Capture payloads** — pull real samples of `session_posts`, turn-status, the
   SSE frames, and the `/forume2` form from a live repo (prerequisite for Gap 2).
3. **Gap 2a** — JSON models + read-only Sessions/Thread view.
4. **Gap 2b** — SSE live consumer.
5. **Gap 2c** — reply composer (write path, confirm-before-send).

Gap 3 is decided up front (native) and shapes 2a–2c.

## Decisions needed before coding

- D1: `username` on `Repo` vs. `user:password` in Keychain? (Gap 1)
- D2: Persist the login cookie in Keychain for reuse, or re-login per launch?
- D3: Confirm we can obtain real sample payloads from a live
  `ollama.openbeagle.org` repo (blocks Gap 2) — turn-status JSON + SSE frames +
  the `forumedit`/`forume2` form.
- D4: Confirm Gap 3 = native (assumed above).

---

> **Note (2026-06-18):** This scoping covers the *agent-client* (anywhere-coding)
> plane. The maintainer has since expanded the vision to a multi-plane **gateway**
> — see [vision-gateway.md](vision-gateway.md). The **journaling** plane
> (embedded offline-first write) is positioned as the nearer, lower-risk pillar
> and is scoped there; the agent-client work here builds on the same auth + the
> Option B read foundation.
