#ifndef STONE_FOSSIL_H
#define STONE_FOSSIL_H

/*
 * StoneFossil — the one and only bridge between the Swift app and the
 * vendored Fossil C core.
 *
 * Design contract (kept deliberately tiny to prevent coupling):
 *   - All entry points run Fossil's own `fossil_main()`, which fully resets
 *     global state on every call (it does `memset(&g,0,sizeof(g))`), so each
 *     invocation is independent.
 *   - Every call into Fossil is serialized behind one internal lock. The
 *     vendored SQLite is built single-threaded (SQLITE_THREADSAFE=0) and
 *     Fossil uses process-global state, so callers must never assume
 *     concurrency. Serialization makes that safe.
 */

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Run an arbitrary Fossil command in-process (e.g. "clone", "init", "sync").
 *
 *   argv  : the command and its arguments, WITHOUT a leading "fossil"
 *           (e.g. {"sync", "https://example.com/repo", "-R", "/path.fossil"}).
 *   out_text : on return, receives a newly malloc()'d, NUL-terminated string
 *              containing captured stdout+stderr. Caller must free() it.
 *              May be NULL if the caller does not want the output.
 *
 * Returns 0 on success, non-zero on failure.
 */
int stone_fossil_run(int argc, const char *const argv[], char **out_text);

/*
 * Set the user identity Fossil uses to attribute clone/commit/sync operations.
 * Overrides the built-in default ("stone"). Pass a non-empty, NUL-terminated
 * name. Safe to call at any time; takes effect on the next Fossil invocation.
 */
void stone_fossil_set_user(const char *user);

/*
 * Point Fossil/OpenSSL at a CA certificate bundle (PEM) for verifying https
 * remotes. iOS has no OpenSSL-readable trust store, so the app passes the path
 * to its bundled cacert.pem. Fossil checks the SSL_CERT_FILE environment
 * variable first, so this simply sets it. Takes effect on the next call.
 */
void stone_fossil_set_ca_file(const char *path);

/*
 * Start an in-process HTTP server bound to 127.0.0.1 on an OS-assigned port,
 * serving the given .fossil repository's web UI with full local access.
 *
 *   repo_path : absolute path to a .fossil repository file.
 *   out_port  : receives the chosen TCP port on success.
 *
 * The server runs on a background thread and handles one request at a time.
 * Returns 0 on success, non-zero on failure.
 */
int stone_fossil_server_start(const char *repo_path, int *out_port);

/*
 * Retarget the already-running server at a different repository, without
 * restarting the socket (the port stays the same). Because each request is
 * served by a fresh `fossil http <repo>` invocation, switching repos is just a
 * matter of swapping the path the next request will use.
 *
 *   repo_path : absolute path to a .fossil repository file.
 *
 * Returns 0 on success, non-zero if no server is running or on failure.
 */
int stone_fossil_server_set_repo(const char *repo_path);

/* Stop the running server, if any. Safe to call when none is running. */
void stone_fossil_server_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* STONE_FOSSIL_H */
