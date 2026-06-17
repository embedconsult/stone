# Design: Caching Fossil-Aware Browser (Option B)

Status: **Draft — for review before implementation**
Date: 2026-06-17

## 1. Problem statement

Stone serves a repository's Fossil web UI from an in-process loopback HTTP
server into a `WKWebView`. Two recurring problems motivate this work:

1. **Sluggish / flaky local serving.** Every HTTP request (page *and* every
   asset: CSS, JS, images) is handled by a fresh `fossil_main()` invocation,
   which does a full DB-open / global-reset cycle. The timeline page in
   particular is slow to appear, and sometimes does not appear at all until the
   user navigates away and back. Per-connection threading helped but did not
   remove the per-request cost.

2. **No way to browse the *remote* repo cheaply.** Users often just want to
   *read* a repo (timeline, a file, a wiki page) that lives on a remote Fossil
   server, without a full local clone and without paying the local-serving cost.
   We want a "Fossil-aware browser" that fetches the remote view and caches it
   in a way optimized for fast, cached, mobile viewing.

The chosen direction (**Option B**) is to make the loopback server a small
**router** that dispatches to in-process **handlers**, one of which is a
**caching proxy** to the remote, keyed by Fossil's content-addressed URL
structure.

## 2. Goals & non-goals

**Goals**
- Two viewing modes per repo: **Working copy** (embedded Fossil, today's
  behavior) and **Remote cached** (read remote through a caching proxy).
- Remove the shared-mutable `g_server.repo_path` retarget hack, which is a race
  when multiple repos / requests interleave.
- Cache aggressively where Fossil's URLs are content-addressed (immutable), and
  conservatively (short TTL + offline fallback) where they are dynamic.
- Stay faithful to upstream Fossil (anti-drift): reuse Fossil's own skin/HTML
  rather than reimplementing pages.

**Non-goals**
- We are **not** implementing real CGI / `fork`+`exec` (`popen2`) — forbidden in
  the iOS sandbox (see §6).
- We are not building a general-purpose web cache; caching policy is specific to
  Fossil's URL classes.
- No write operations through the remote-cached mode in this design (read-only
  first; see open question in §9).

## 3. Architecture overview

Today the loopback server holds a single `g_server.repo_path` and every request
runs `fossil http <that repo>`. We replace this with a router:

```
            ┌──────────────────────────────────────────────┐
  WKWebView │  GET /local/<repoID>/timeline                 │
   request  │  GET /remote/<repoID>/raw/<HASH>              │
 ─────────► │  GET /hook/<name>/...                         │
            └──────────────┬───────────────────────────────┘
                           │  (method, path, headers, body)
                           ▼
                   ┌───────────────┐
                   │    Router     │  parse leading path segment
                   └───────┬───────┘
            ┌──────────────┼───────────────────────────┐
            ▼              ▼                             ▼
   ┌────────────────┐ ┌─────────────────────┐ ┌─────────────────┐
   │ /local handler │ │ /remote handler     │ │ /hook/<name>    │
   │ embedded Fossil│ │ LibreSSL caching    │ │ in-process CGI  │
   │ fossil_main()  │ │ proxy → remote      │ │ analogue        │
   └────────────────┘ └─────────────────────┘ └─────────────────┘
```

### Handler contract

Every handler implements one function shape:

```
handle(method, path, headers, body) -> (status, headers, body)
```

The router owns the socket/threading; handlers are pure request→response and
never touch sockets. This is what lets us drop `g_server.repo_path`: the repo to
serve comes from the *path* (`/local/<repoID>/…`), not from shared mutable state.

### Handlers

| Route                 | Backend                         | Purpose                                            |
|-----------------------|---------------------------------|----------------------------------------------------|
| `/local/<repoID>/…`   | embedded Fossil `fossil_main()` | Working-copy mode (today's behavior, de-raced)     |
| `/remote/<repoID>/…`  | LibreSSL HTTPS → remote + cache | Remote-cached mode (the Fossil-aware browser)      |
| `/hook/<name>/…`      | registered in-process handler   | Extension point; CGI analogue (see §6)             |

## 4. Caching strategy (remote handler)

Fossil URLs fall into content-addressed (immutable) and dynamic classes. We key
the cache on the request path and apply per-class policy:

**Immutable — cache forever (content-addressed by hash/built-in):**
- `/raw/<HASH>` — raw artifact content
- `/artifact/<HASH>` / `/file?ci=<HASH>` — specific artifact versions
- `/doc/<HASH>/…` — embedded docs at a pinned checkin
- `/builtin/…` — Fossil's bundled CSS/JS/images (versioned by build)

**Dynamic — short TTL + offline fallback (serve stale when offline):**
- `/timeline`, `/home`, `/wiki`, `/dir`, `/brlist`, `/taglist`, branch tips

Cache store: an on-disk directory per repo keyed by a hash of (path, query),
storing status + headers + body. Immutable entries never expire; dynamic entries
carry a TTL and a "last good" copy used as offline fallback.

## 5. Phased rollout

1. **Quick win — persistent WebView cache.** Switch `RepoWebView`'s
   `WKWebsiteDataStore` from `.nonPersistent()` to a persistent store and emit
   cacheable headers for immutable assets. Cheapest latency win; no server
   restructure. (`ios/Stone/Views/RepoWebView.swift`)
2. **Router refactor.** Introduce the router + handler contract in the loopback
   server. Move current behavior to the `/local/<repoID>` handler. **Delete the
   `g_server.repo_path` retarget hack** and `stone_fossil_server_set_repo`.
   (`ios/FossilBridge/StoneFossil.c` / `.h`)
3. **Remote caching proxy.** Implement `/remote/<repoID>` over LibreSSL with the
   §4 URL-class cache.
4. **UI mode toggle.** Per-repo switch: Working copy ↔ Remote cached.
   (`RepoDetailView` / `RepoWebView`)
5. **Hook extension point.** `/hook/<name>` registry (in-process CGI analogue).
6. **Mobile skin.** Apply a mobile-optimized view via Fossil's *own* skin
   mechanism rather than rewriting pages (anti-drift).

## 6. CGI / hook verdict

The user asked whether we can support `cgi-bin` execution like a real Fossil
server. **No — not as real CGI.** Fossil's `/ext` page (`src/extcgi.c`) relays
to external programs via `popen2()` (i.e. `fork`+`exec`), which the iOS sandbox
forbids. The faithful analogue is an **in-process hook**: `/hook/<name>` maps to
a registered Swift/C handler implementing the same request→response contract.
This gives the *extension-point* benefit of CGI without spawning processes.

## 7. Concurrency & state

- Router owns accept loop; each connection handled on its own short-lived thread
  (already in place).
- Embedded Fossil work stays serialized behind the existing internal lock
  (`fossil_main()` resets process-global state; SQLite is `THREADSAFE=0`).
- The remote proxy's network + cache I/O can run outside that lock since it does
  not enter `fossil_main()`.
- Removing `g_server.repo_path` eliminates the cross-request retarget race that
  contributed to "page doesn't always appear."

## 8. Risks

- Cache correctness for dynamic pages (stale timeline). Mitigated by short TTL +
  explicit refresh + treating only content-addressed URLs as immutable.
- LibreSSL HTTPS client path must verify against the bundled `cacert.pem`
  (already wired via `SSL_CERT_FILE` / `stone_fossil_set_ca_file`).
- Skin divergence from upstream — mitigated by using Fossil's skin mechanism.

## 9. Open questions (need decision before/with implementation)

1. **Remote-browse auth scope.** Start read-only against *public* repos only, or
   carry the Keychain credential into the remote proxy from day one (to browse
   private repos)?
2. **Mobile skin approach.** Ship a custom Fossil skin, or rely on Fossil's
   existing responsive defaults plus a viewport/meta shim?
