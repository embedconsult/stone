# Ollama-Codex remote-development client (Plane 3)

**Status:** Direction / concept (2026-07-07). Instantiates **plane 3 (remote agent-client control)** from [vision-gateway.md](vision-gateway.md) for one specific remote: the **Ollama-Codex** development workbench served at `https://ollama.openbeagle.org`. Extends [agent-client-scoping.md](agent-client-scoping.md) (the three gaps) and reuses the [option-b-caching-browser.md](option-b-caching-browser.md) router/hook model. This doc owns the Ollama-Codex-client design; it does not re-explain plane/contract mechanics — see the owners.

Ollama-Codex is a *separate* project (a Fossil-hosted, forum-driven multi-agent coding workbench). Stone does **not** host its development; Stone becomes the **customizable, voice-capable field client** for driving it — more flexible than a generic LLM phone app, and usable in poor-network conditions.

## Thesis

Stone drives Ollama-Codex development through **Fossil-native mechanisms**, deferring all Provider/Runner execution to the server. The control plane is already a syncable message bus: forum threads are bound 1:1 to runner sessions; posting into a thread queues a turn; the server daemon polls and drives it. So Stone's job is **compose intent → queue it as forum activity on the local clone → sync → present responses**, with voice and (later) graphical review on top.

This is a deliberate **v1 = remote-execution** choice. Local code-editing tools and on-phone model execution are the eventual goal but are backlog (the latter possibly long-horizon, gated on phone hardware). Remote-first is usable much sooner and degrades gracefully on cellular.

## What Stone already has (survey, 2026-07-07)

- **Embedded Fossil 2.26**, `fossil_main()` made re-entrant via `scripts/fossil-inprocess.patch`; a loopback HTTP server (`FossilBridge/StoneFossil.c`) runs `fossil http <repo> --localauth` per request, and a `WKWebView` (`RepoWebView.swift`) loads `http://localhost:<port>/`. Full clones supported (`RepoStore.swift`).
- **Auth foundation:** `CredentialStore` stores the clone password in Keychain (per repo UUID); username rides in the remote URL. `RemoteSession.swift` already implements Fossil `/login` (POST u/p → captures the `fossil-*` cookie) for remote `/ext/agent` endpoints — **built, not yet wired to UI**.
- **No fork/exec on iOS** → the CGI analogue is an **in-process `/hook/<name>` handler registry** (Option B), not a subprocess. This is the mechanism for a "CGI-BIN mobile agent."
- **Read-only browsing** = render Fossil's own server HTML unchanged (anti-drift). Multi-repo list exists; **Sessions/thread UI does not** (agent-client-scoping Gap 2).

## Architecture

Two cooperating surfaces inside Stone, in parallel:

1. **Local session (primary UI).** The existing loopback `fossil http --localauth` server + WKWebView, operating on **local clones** — including a local clone of the **Ollama-Codex** repo. Serves browse/read, cached content, and offline composition. Works fully offline.
2. **Remote-session access.** `RemoteSession` (login cookie) to `ollama.openbeagle.org` for the things only the server can do: driving Provider/Runner turns, and real-time status. Runs *beside* the local session, not replacing it.

### The Ollama-Codex mobile agent (WASM, via a local clone)

- The agent is **Ollama-Codex's own mobile agent, compiled to WASM**, built **from a local clone of the Ollama-Codex repo on the device** — *not* vendored into the Stone source tree. Stone copies as little Ollama-Codex code as possible: only **hooks to the WASM executable** + remote-session access.
- It runs as a Stone **`/hook/<name>` in-process handler** (no CGI subprocess). Its job in v1 is the **UI/data plane**: get structured intent into the local Fossil clone (a forum post that queues session work; a ticket; a journal note) and **trigger synchronization** — it does **not** execute the Provider/Runner work locally.
- **Update path:** the server builds and publishes the WASM artifact (e.g. as an unversioned artifact); the phone adopts the server-provided version once synchronized. The phone never builds it.

### Deferral model (the core loop)

```
compose intent (voice/text)
  → local WASM hook writes it into the LOCAL Ollama-Codex clone
     (forum post to a bound session thread / ticket / journal)   [works offline]
  → fossil sync  (on reconnect)                                   [Fossil-native queue]
  → server daemon polls the thread, drives the Provider/Runner turn
  → responses arrive as forum replies + status
  → Stone pulls (sync) and/or streams (SSE) them back            [poll when offline-capable, SSE when connected]
```

Queuing work is a **local Fossil commit (a forum post) that syncs later** — so offline queues and caching are largely **Fossil-native**, per the standing convention of using native Fossil communication types. No bespoke queue protocol.

## Transport (hybrid — decided)

- **Primary transport: native Fossil DB + HTTP sync.** Reads come from the local clone (full contents cached; the search-tool data is copied too, allowed to be **stale until a solid connection**, no on-phone re-index in v1). Outbound work is a synced forum post.
- **JSON as a management layer**, not the primary read path — for structured actions/status where scraping server HTML would be brittle. Prefer the **local database** for reads where possible.
- **SSE + JSON for real-time status.** When a live connection exists, subscribe to the server's live-events stream (`:8443`) for turn heartbeats / replies, so the operator sees real-time confidence the work is progressing. When offline, fall back to poll-on-sync.

Hybrid is the most complex option (it must support both local read/compose and remote execution across all network conditions) but is what makes Stone usable everywhere.

## Auth

- Reuse the **existing `RemoteSession` login** — the human's Fossil login (Keychain password + URL username) establishes the cookie; **the login secures the SSE connection** and the `/ext/agent` JSON calls. Permissions are exactly the logged-in user's Fossil capabilities; **no phone-special rate limits** — rate limiting is ordinary user management on the server.
- Open detail: the server login page may live **un-rendered/headless** (cookie established without painting the page) for performance, with the visible UI served from the local loopback pages — a **bridge from the headless remote session to the local WebView**. (Decision below.)

## Voice UI

- Start with **Apple's hosted speech-to-text and text-to-speech**; a native/on-device engine is backlog (privacy is not paramount here). The critical element is not the engine but a **fluid speech-based interaction loop** — dictate an instruction to a session, hear its reply/summary — so development can happen hands-busy / on the move.

## Multi-session

- Stone should let the operator **browse to the various active sessions** (as it browses repos today), converging on a **mobile-optimized skin** iteratively. This wants a server-side notion of which sessions are *active vs idle* (Ollama-Codex ticket `1e647f91f1`, session-status) so the client can show live state.

## Ollama-Codex-side prerequisites (server, cross-referenced)

These are **Ollama-Codex** work items that this client depends on (tracked there, not in Stone):

1. **Structured JSON management API** over the existing `/ext/` surface — threads, posts, tickets, diffs, search, session status — so Stone acts on data, not scraped HTML. (Relates to the "portable agent toolset" direction, OC `beb51d8`.)
2. **Remote SSE auth/CORS** — the `:8443` stream reachable + authenticated cross-origin from a non-CGI client (CSP `connect-src`, cookie/token).
3. **Forum-as-work-queue contract** for external clients — a clean "post = queue a turn" contract incl. reply correlation + status (OC `ddcb11d7` adjacent).
4. **WASM build target** for the Ollama-Codex mobile agent + its published-artifact update path.

## Decisions locked (from owner, 2026-07-07)

- Transport = **hybrid**; native DB + HTTP sync primary; JSON management layer; SSE+JSON for status.
- WASM core carries **real UI/data logic** (get data into the repo, trigger sync), not just sync — grows over time.
- v1 = **remote execution only**; no on-phone model or local editing (backlog; on-phone model possibly long-horizon).
- Full-content caching + copied search data, **stale-until-connected** acceptable.
- STT/TTS via **Apple** first; goal is a fluid speech loop.
- Permissions = logged-in Fossil user; rate limits = ordinary user management.
- Mobile agent built **from a local Ollama-Codex clone**, run via `/hook`, **minimal OC code copied into Stone**.
- Graphical code review + localized-file-review = **backlog** (nice-to-have for Stone, not v1).

## Contracts to freeze (open — answer before building)

- **C-A (login bridge):** exact mechanism for a headless remote login cookie feeding both SSE and JSON while the visible UI stays on local loopback pages. Where does the cookie live, and how does the WebView reach the remote when needed?
- **C-B (queue idempotency):** the forum-post-as-queue contract — how a client marks intent, correlates the reply, and dedups if the same post syncs twice or the thread advanced while offline. Follow Fossil conventions.
- **C-C (agent artifact):** how the server publishes the WASM mobile-agent (unversioned artifact name + version signal) and how the phone adopts the synced version safely.
- **C-D (search-data copy):** what subset of the server's vector/search tables Stone caches, and the staleness/refresh policy.
- **C-E (session addressing):** the stable identifiers Stone uses to list + route to active sessions (depends on the OC session-status API).

## Phasing

1. **Gap-1 already done** (login/cookie). **Gap 2 (Sessions/thread UI + composer + SSE status)** over `/ext/agent` + `:8443` — the v1 heart.
2. WASM mobile-agent hook + sync-trigger UI (compose → local clone → sync).
3. Voice loop (Apple STT/TTS) over the composer.
4. Mobile-optimized skin; multi-session cockpit.
5. Backlog: localized-file-review UI, on-phone editing, on-phone model.
