/*
 * StoneFossil — bridge implementation.
 *
 * Responsibilities, each isolated in its own helper:
 *   1. invoke_fossil()          run fossil_main() once, capturing stdout/stderr.
 *   2. stone_fossil_run()       public wrapper for one-shot commands.
 *   3. the loopback HTTP server reads one request, hands it to
 *      `fossil http <repo> --in REQ --out RESP --localauth`, returns the reply.
 *
 * The server mirrors exactly how Fossil's own `server`/`ui` commands dispatch
 * work (spawning `fossil http --in --out` per connection) — but in-process,
 * so no fork/exec is needed (and none is permitted on iOS).
 */

#include "StoneFossil.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

/* Fossil's own bundled SQLite (extsrc/sqlite3.c, compiled into this same
 * archive -- see build-fossil-xcframework.sh/linux-crosslink-test.sh). Used
 * only by stone_fossil_query() below, which is the ONE place other than
 * Fossil's own command dispatch that touches a .fossil file's SQLite
 * directly -- deliberately the same library instance. */
#include "sqlite3.h"

/* Provided by the vendored Fossil core (src/main.c). */
extern int fossil_main(int argc, char **argv);

/* One lock guards every entry into Fossil (global state + single-threaded
 * SQLite). It is recursive only conceptually: we never re-enter under it. */
static pthread_mutex_t g_fossil_lock = PTHREAD_MUTEX_INITIALIZER;

/* ------------------------------------------------------------------ */
/* exit() interception                                                 */
/* ------------------------------------------------------------------ */
/*
 * Fossil is built around one-process-per-request: after serving an HTTP
 * request it funnels through fossil_exit() -> exit(), tearing down the whole
 * process. That is wrong for an in-process server, so the Fossil core is
 * compiled with -Dexit=stone_exit (see the build scripts). When a Fossil call
 * is "armed" (we are inside invoke_fossil), stone_exit longjmp()s back to the
 * shim instead of terminating; otherwise it behaves like the real _exit().
 *
 * This is safe because fossil_exit() already calls db_close() before exiting,
 * so the repository is flushed and closed before we unwind. Each fossil_main()
 * begins with memset(&g,0,...), so global state is reset for the next request.
 * The single g_fossil_lock guarantees only one armed call at a time, so a
 * single jmp_buf suffices.
 */
static jmp_buf g_exit_jmp;
static int g_exit_armed = 0;
static int g_exit_code = 0;

/* Replaces exit() inside the Fossil core (via -Dexit=stone_exit). */
__attribute__((noreturn)) void stone_exit(int rc) {
    if (g_exit_armed) {
        g_exit_code = rc;
        g_exit_armed = 0;
        longjmp(g_exit_jmp, 1);
    }
    _exit(rc);
}

/* ------------------------------------------------------------------ */
/* Temp-file helpers                                                   */
/* ------------------------------------------------------------------ */

/* Build a unique temp path and open it. Returns fd (>=0) or -1.
 * On success, *out_path is a malloc()'d path the caller must free+unlink. */
static int open_tempfile(const char *tag, char **out_path) {
    const char *dir = getenv("TMPDIR");
    if (dir == NULL || dir[0] == '\0') dir = "/tmp";

    size_t need = strlen(dir) + strlen(tag) + 32;
    char *path = (char *)malloc(need);
    if (path == NULL) return -1;
    snprintf(path, need, "%s/stone-%s-XXXXXX", dir, tag);

    int fd = mkstemp(path);
    if (fd < 0) {
        free(path);
        return -1;
    }
    *out_path = path;
    return fd;
}

/* Read an entire file into a NUL-terminated malloc()'d buffer.
 * Returns the byte length (excluding the terminator), or -1 on error. */
static long read_file_all(const char *path, char **out_buf) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return -1; }
    rewind(f);

    char *buf = (char *)malloc((size_t)n + 1);
    if (buf == NULL) { fclose(f); return -1; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[got] = '\0';
    *out_buf = buf;
    return (long)got;
}

/* ------------------------------------------------------------------ */
/* Core: run fossil_main() with stdout/stderr captured to a buffer.    */
/* ------------------------------------------------------------------ */

/* Fossil needs a user identity for clone/commit. iOS sets no USER environment
 * variable and there is no global Fossil config, so seed a sensible default
 * once. setenv(..., 0) leaves any identity the host already provided intact. */
static pthread_once_t g_env_once = PTHREAD_ONCE_INIT;
static void stone_init_env(void) {
    setenv("USER", "stone", 0);
    setenv("FOSSIL_USER", "stone", 0);
}

void stone_fossil_set_user(const char *user) {
    if (user == NULL || user[0] == '\0') return;
    setenv("USER", user, 1);
    setenv("FOSSIL_USER", user, 1);
}

void stone_fossil_set_ca_file(const char *path) {
    if (path == NULL || path[0] == '\0') return;
    setenv("SSL_CERT_FILE", path, 1);
}

void stone_fossil_set_home(const char *path) {
    if (path == NULL || path[0] == '\0') return;
    setenv("FOSSIL_HOME", path, 1);
}

/* argv here is the FULL vector including "fossil" at index 0. */
static int invoke_fossil(int argc, char *argv[], char **out_text) {
    pthread_once(&g_env_once, stone_init_env);
    pthread_mutex_lock(&g_fossil_lock);

    char *cap_path = NULL;
    int cap_fd = -1;
    int saved_out = -1, saved_err = -1;

    if (out_text != NULL) {
        cap_fd = open_tempfile("out", &cap_path);
        if (cap_fd >= 0) {
            fflush(stdout);
            fflush(stderr);
            saved_out = dup(STDOUT_FILENO);
            saved_err = dup(STDERR_FILENO);
            dup2(cap_fd, STDOUT_FILENO);
            dup2(cap_fd, STDERR_FILENO);
        }
    }

    /* Arm exit interception so a request that ends in fossil_exit()/exit()
     * unwinds back here instead of terminating the process. */
    int rc;
    g_exit_code = 0;
    if (setjmp(g_exit_jmp) == 0) {
        g_exit_armed = 1;
        rc = fossil_main(argc, argv);
    } else {
        /* Returned via stone_exit()/longjmp after serving the request. */
        rc = g_exit_code;
    }
    g_exit_armed = 0;

    if (out_text != NULL && cap_fd >= 0) {
        fflush(stdout);
        fflush(stderr);
        dup2(saved_out, STDOUT_FILENO);
        dup2(saved_err, STDERR_FILENO);
        close(saved_out);
        close(saved_err);
        close(cap_fd);

        char *buf = NULL;
        if (read_file_all(cap_path, &buf) >= 0) {
            *out_text = buf;
        } else {
            *out_text = NULL;
        }
        unlink(cap_path);
        free(cap_path);
    }

    pthread_mutex_unlock(&g_fossil_lock);
    return rc;
}

int stone_fossil_run(int argc, const char *const argv[], char **out_text) {
    if (out_text) *out_text = NULL;

    /* Prepend "fossil" to form the full argument vector. */
    int full = argc + 1;
    char **vec = (char **)calloc((size_t)full + 1, sizeof(char *));
    if (vec == NULL) return -1;
    vec[0] = strdup("fossil");
    for (int i = 0; i < argc; i++) vec[i + 1] = strdup(argv[i]);

    /* Fossil edits the argv it is given in place: find_option() removes
     * each option it consumes by shifting the later entries left, so after
     * e.g. "bundle import B -R R --publish --force" vec[] holds some
     * pointers twice and others not at all. Freeing vec[] afterwards was a
     * double free (SIGABRT in stone_fossil_run on the phone, sending a
     * conversation reply). Free the strings from this untouched copy. */
    char **owned = (char **)malloc((size_t)full * sizeof(char *));
    if (owned == NULL) {
        for (int i = 0; i < full; i++) free(vec[i]);
        free(vec);
        return -1;
    }
    memcpy(owned, vec, (size_t)full * sizeof(char *));

    int rc = invoke_fossil(full, vec, out_text);

    for (int i = 0; i < full; i++) free(owned[i]);
    free(owned);
    free(vec);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Loopback HTTP server                                                */
/* ------------------------------------------------------------------ */

typedef struct {
    int listen_fd;
    int port;
    char *repo_path;
    pthread_t thread;
    volatile int running;
} ServerState;

static ServerState g_server = {.listen_fd = -1, .port = 0, .repo_path = NULL,
                               .running = 0};

/* Guards g_server.repo_path so it can be swapped (retargeted) from another
 * thread while the accept loop is reading it between requests. */
static pthread_mutex_t g_repo_lock = PTHREAD_MUTEX_INITIALIZER;

/* Read exactly n bytes worth of one HTTP request from the socket into a temp
 * file: request line + headers (until CRLFCRLF) plus Content-Length body.
 * Returns a malloc()'d temp path on success (caller unlink+free), or NULL. */
static char *slurp_request(int fd) {
    size_t cap = 8192, len = 0;
    char *buf = (char *)malloc(cap);
    if (buf == NULL) return NULL;

    long header_end = -1;       /* index just past the CRLFCRLF */
    long content_length = 0;
    long total_needed = -1;

    for (;;) {
        if (len == cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (nb == NULL) { free(buf); return NULL; }
            buf = nb;
        }
        ssize_t r = read(fd, buf + len, cap - len);
        if (r < 0) {
            if (errno == EINTR) continue;
            free(buf);
            return NULL;
        }
        if (r == 0) break; /* peer closed */
        len += (size_t)r;

        if (header_end < 0) {
            /* Look for end of headers. */
            for (size_t i = 3; i < len; i++) {
                if (buf[i - 3] == '\r' && buf[i - 2] == '\n' &&
                    buf[i - 1] == '\r' && buf[i] == '\n') {
                    header_end = (long)i + 1;
                    break;
                }
            }
            if (header_end >= 0) {
                /* Parse Content-Length (case-insensitive) within headers. */
                for (long i = 0; i + 15 < header_end; i++) {
                    if (strncasecmp(buf + i, "content-length:", 15) == 0) {
                        content_length = strtol(buf + i + 15, NULL, 10);
                        if (content_length < 0) content_length = 0;
                        break;
                    }
                }
                total_needed = header_end + content_length;
            }
        }
        if (total_needed >= 0 && (long)len >= total_needed) break;
    }

    if (header_end < 0) { free(buf); return NULL; }

    char *path = NULL;
    int tfd = open_tempfile("req", &path);
    if (tfd < 0) { free(buf); return NULL; }
    long want = (total_needed >= 0) ? total_needed : (long)len;
    if (want > (long)len) want = (long)len;
    ssize_t w = write(tfd, buf, (size_t)want);
    close(tfd);
    free(buf);
    if (w != want) { unlink(path); free(path); return NULL; }
    return path;
}

/* Write the whole response buffer to the socket, then close the write side. */
static void send_all(int fd, const char *data, long len) {
    long off = 0;
    while (off < len) {
        ssize_t w = write(fd, data + off, (size_t)(len - off));
        if (w < 0) {
            if (errno == EINTR) continue;
            break;
        }
        off += w;
    }
    shutdown(fd, SHUT_WR);
}

static void handle_connection(int cfd) {
    char *req_path = slurp_request(cfd);
    if (req_path == NULL) return;

    char *resp_path = NULL;
    int rfd = open_tempfile("resp", &resp_path);
    if (rfd < 0) { unlink(req_path); free(req_path); return; }
    close(rfd); /* fossil opens it by name for writing */

    char baseurl[64];
    /* The listening socket is deliberately IPv4-only (INADDR_LOOPBACK).
     * Use its literal address in Fossil's generated redirects too: WKWebView
     * may resolve localhost to ::1 first, where this server is not listening. */
    snprintf(baseurl, sizeof(baseurl), "http://127.0.0.1:%d", g_server.port);

    /* Snapshot the current repo path so a concurrent retarget can't free it
     * out from under this request. */
    pthread_mutex_lock(&g_repo_lock);
    char *repo = g_server.repo_path ? strdup(g_server.repo_path) : NULL;
    pthread_mutex_unlock(&g_repo_lock);
    if (repo == NULL) {
        unlink(req_path); free(req_path);
        unlink(resp_path); free(resp_path);
        return;
    }

    char *argv[] = {
        "fossil", "http", repo,
        "--in", req_path,
        "--out", resp_path,
        "--ipaddr", "127.0.0.1",
        "--baseurl", baseurl,
        "--localauth",   /* localhost gets full admin/read-write access */
        "--nossl",
        "--nocompress",
        NULL};
    int argc = (int)(sizeof(argv) / sizeof(argv[0])) - 1;

    invoke_fossil(argc, argv, NULL);
    free(repo);

    char *resp = NULL;
    long n = read_file_all(resp_path, &resp);
    if (n >= 0 && resp != NULL) {
        send_all(cfd, resp, n);
        free(resp);
    }

    unlink(req_path);
    free(req_path);
    unlink(resp_path);
    free(resp_path);
}

/* Serve one accepted connection, then close it. Runs on its own detached
 * thread (see accept_loop). The Fossil work it triggers is still serialized by
 * g_fossil_lock inside invoke_fossil; threading here only keeps a slow or idle
 * socket from blocking other connections. */
static void *connection_thread(void *arg) {
    int cfd = *(int *)arg;
    free(arg);
    handle_connection(cfd);
    close(cfd);
    return NULL;
}

static void *accept_loop(void *arg) {
    (void)arg;
    while (g_server.running) {
        int cfd = accept(g_server.listen_fd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            break; /* listen socket closed -> shut down */
        }
        /* Hand each connection to its own short-lived thread. A browser opens
         * several connections per page (and speculative/preconnect sockets that
         * may stay idle); serving them serially here would let one stalled
         * read() block the request the page is actually waiting on. */
        int *pfd = (int *)malloc(sizeof(int));
        if (pfd == NULL) { close(cfd); continue; }
        *pfd = cfd;
        pthread_t t;
        if (pthread_create(&t, NULL, connection_thread, pfd) != 0) {
            free(pfd);
            close(cfd);
            continue;
        }
        pthread_detach(t);
    }

    /* Falling out of the loop means the listening socket is no longer being
     * serviced (either a deliberate shutdown via stone_fossil_server_stop(),
     * which already closed listen_fd itself, or accept() failing for a
     * reason other than EINTR -- e.g. fd exhaustion under load from a large
     * repo's many concurrent WKWebView connections). Either way, reflect
     * that here so a future stone_fossil_server_start() call sees a truthful
     * g_server.running and can recover by starting a fresh listener, instead
     * of believing a silently-dead server is still healthy and handing back
     * a URL nothing is listening on -- which is what "Couldn't load the
     * local Fossil page: Could not connect to the server" looks like from
     * the WebView's side once this happens once, and never goes away for
     * the rest of the app session (see the fix note below).
     */
    g_server.running = 0;
    if (g_server.listen_fd >= 0) {
        close(g_server.listen_fd);
        g_server.listen_fd = -1;
    }
    return NULL;
}

int stone_fossil_server_start(const char *repo_path, int *out_port) {
    if (repo_path == NULL || out_port == NULL) return -1;
    if (g_server.running) {
        /* Already up -- report the real port. Previously this returned
         * success without ever touching *out_port, which left the caller's
         * `var port: Int32 = 0` at its default and produced a URL like
         * http://127.0.0.1:0/ -- an address nothing can ever connect to.
         * That silently-wrong URL is exactly the "Couldn't connect to the
         * server" failure reported for BQ2: whatever repo is opened right
         * after the accept loop dies (see the cleanup added above) hits
         * this branch, since g_server.running was stale-true. */
        *out_port = g_server.port;
        return 0;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); /* 127.0.0.1 only */
    addr.sin_port = 0;                              /* OS-assigned port */

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &alen) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 16) < 0) {
        close(fd);
        return -1;
    }

    g_server.listen_fd = fd;
    g_server.port = ntohs(addr.sin_port);
    g_server.repo_path = strdup(repo_path);
    g_server.running = 1;

    if (pthread_create(&g_server.thread, NULL, accept_loop, NULL) != 0) {
        g_server.running = 0;
        close(fd);
        g_server.listen_fd = -1;
        free(g_server.repo_path);
        g_server.repo_path = NULL;
        return -1;
    }

    *out_port = g_server.port;
    return 0;
}

int stone_fossil_server_set_repo(const char *repo_path) {
    if (repo_path == NULL) return -1;
    if (!g_server.running) return -1;

    char *copy = strdup(repo_path);
    if (copy == NULL) return -1;

    pthread_mutex_lock(&g_repo_lock);
    free(g_server.repo_path);
    g_server.repo_path = copy;
    pthread_mutex_unlock(&g_repo_lock);
    return 0;
}

void stone_fossil_server_stop(void) {
    if (!g_server.running) return;
    g_server.running = 0;
    if (g_server.listen_fd >= 0) {
        shutdown(g_server.listen_fd, SHUT_RDWR);
        close(g_server.listen_fd);
        g_server.listen_fd = -1;
    }
    pthread_join(g_server.thread, NULL);
    pthread_mutex_lock(&g_repo_lock);
    free(g_server.repo_path);
    g_server.repo_path = NULL;
    pthread_mutex_unlock(&g_repo_lock);
    g_server.port = 0;
}

/* ------------------------------------------------------------------ */
/* Read-only query (MaintainerRequestScanner)                          */
/* ------------------------------------------------------------------ */

/* Append `srclen` bytes at `src` to the growable buffer `*bufp`/`*lenp`
 * (capacity `*capp`), growing it as needed. Returns 0 on success, -1 on
 * allocation failure (buffer already freed in that case). */
static int query_buf_append(char **bufp, size_t *lenp, size_t *capp,
                             const char *src, size_t srclen) {
    size_t need = *lenp + srclen + 1;
    if (need > *capp) {
        size_t newcap = *capp;
        while (newcap < need) newcap *= 2;
        char *nb = (char *)realloc(*bufp, newcap);
        if (nb == NULL) {
            free(*bufp);
            *bufp = NULL;
            return -1;
        }
        *bufp = nb;
        *capp = newcap;
    }
    memcpy(*bufp + *lenp, src, srclen);
    *lenp += srclen;
    (*bufp)[*lenp] = '\0';
    return 0;
}

int stone_fossil_query(const char *repo_path, const char *sql, char **out_text) {
    if (repo_path == NULL || sql == NULL || out_text == NULL) return -1;
    *out_text = NULL;

    sqlite3 *db = NULL;
    /* Read-only + no-mutex, same reasoning as the caller this replaces: this
     * must never block on, or contend with, a write lock the embedded
     * Fossil engine or an in-flight sync might be holding. */
    int flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX;
    if (sqlite3_open_v2(repo_path, &db, flags, NULL) != SQLITE_OK || db == NULL) {
        if (db) sqlite3_close(db);
        return -1;
    }

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK || stmt == NULL) {
        sqlite3_close(db);
        return -1;
    }

    size_t cap = 4096, len = 0;
    char *buf = (char *)malloc(cap);
    if (buf == NULL) {
        sqlite3_finalize(stmt);
        sqlite3_close(db);
        return -1;
    }
    buf[0] = '\0';

    int rc;
    int failed = 0;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        int n = sqlite3_column_count(stmt);
        for (int i = 0; i < n; i++) {
            if (i > 0 && query_buf_append(&buf, &len, &cap, "\x1F", 1) != 0) {
                failed = 1;
                break;
            }
            const unsigned char *text = sqlite3_column_text(stmt, i);
            if (text != NULL &&
                query_buf_append(&buf, &len, &cap, (const char *)text, strlen((const char *)text)) != 0) {
                failed = 1;
                break;
            }
        }
        if (failed) break;
        if (query_buf_append(&buf, &len, &cap, "\x1E", 1) != 0) {
            failed = 1;
            break;
        }
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);

    if (failed || rc != SQLITE_DONE) {
        free(buf);
        return -1;
    }

    *out_text = buf;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Cards (the console's card/NAME definitions)                         */
/* ------------------------------------------------------------------ */
/*
 * The same meaning as OCX's src/ocx/fossil/cards.cr and
 * src/ocx/commands/cards.cr (ollama check-in 973aca3f4c), checked against
 * its shared examples by scripts/linux-cards-driver.c. All JSON is read and
 * written by SQLite's own JSON functions, on an in-memory connection; each
 * repository is read on its own read-only connection, as in
 * stone_fossil_query.
 */

#define CARD_WRITTEN "%Y-%m-%dT%H:%M:%SZ"
/* The same, inside a sqlite3_mprintf format. */
#define CARD_WRITTEN_F "%%Y-%%m-%%dT%%H:%%M:%%SZ"
#define CARD_MAX_KEYS 64

/* The first column of the first row of `sql`, or NULL (no row, a NULL
 * value, or an error). Free with sqlite3_free. */
static char *card_scalar(sqlite3 *db, const char *sql) {
    sqlite3_stmt *stmt = NULL;
    char *out = NULL;
    if (sql == NULL || sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return NULL;
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL)
        out = sqlite3_mprintf("%s", (const char *)sqlite3_column_text(stmt, 0));
    sqlite3_finalize(stmt);
    return out;
}

/* `path` of the definition when its JSON type is `type` ("text",
 * "integer", "array", "object", or "boolean" for true/false), else NULL.
 * Objects and arrays come back as JSON text. Free with sqlite3_free. */
static char *card_def(sqlite3 *w, const char *def, const char *path, const char *type) {
    sqlite3_stmt *stmt = NULL;
    char *out = NULL;
    const char *sql = "SELECT CASE WHEN ?3 = 'boolean' THEN json_type(?1, ?2) IN ('true','false')"
                      " ELSE json_type(?1, ?2) = ?3 END, json_extract(?1, ?2)";
    if (sqlite3_prepare_v2(w, sql, -1, &stmt, NULL) != SQLITE_OK) return NULL;
    sqlite3_bind_text(stmt, 1, def, -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, path, -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 3, type, -1, SQLITE_STATIC);
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1)
        out = sqlite3_mprintf("%s", sqlite3_column_type(stmt, 1) == SQLITE_NULL
                                        ? "" : (const char *)sqlite3_column_text(stmt, 1));
    sqlite3_finalize(stmt);
    return out;
}

static int card_is_word(const char *s) {
    if (s == NULL || *s == '\0') return 0;
    for (; *s; s++) if (!((*s >= 'a' && *s <= 'z') || *s == '_')) return 0;
    return 1;
}

/* A field name -> SQL expression map, in insertion order. */
typedef struct {
    int n;
    char *key[CARD_MAX_KEYS];
    char *expr[CARD_MAX_KEYS];
} card_map;

static void card_map_set(card_map *m, const char *key, char *expr) {
    for (int i = 0; i < m->n; i++) {
        if (strcmp(m->key[i], key) == 0) {
            sqlite3_free(m->expr[i]);
            m->expr[i] = expr;
            return;
        }
    }
    if (m->n == CARD_MAX_KEYS) { sqlite3_free(expr); return; }
    m->key[m->n] = sqlite3_mprintf("%s", key);
    m->expr[m->n++] = expr;
}

static const char *card_map_get(const card_map *m, const char *key) {
    for (int i = 0; i < m->n; i++) if (strcmp(m->key[i], key) == 0) return m->expr[i];
    return NULL;
}

static void card_map_free(card_map *m) {
    for (int i = 0; i < m->n; i++) { sqlite3_free(m->key[i]); sqlite3_free(m->expr[i]); }
    m->n = 0;
}

static int card_has(char *const list[], int n, const char *key) {
    for (int i = 0; i < n; i++) if (strcmp(list[i], key) == 0) return 1;
    return 0;
}

/* One repository's matching items as a JSON array (sqlite3_free), "[]" when
 * it has none or lacks a table or column; its newest dated event goes to
 * *as_of. NULL when the repository can't be read. */
static char *card_repo_rows(const char *repo_path, const char *kind, const char *tag,
                            const char *value, const char *login, sqlite3_int64 seconds,
                            const char *now, char *const fields[], int nfields, char **as_of) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(repo_path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NULL;
    }
    char *out = NULL;
    card_map source = {0};
    char *columns[CARD_MAX_KEYS];
    int ncolumns = 0;
    const char *table = strcmp(kind, "tickets") == 0 ? "ticket"
                      : strcmp(kind, "checkins_tagged") == 0 ? "event" : "forumpost";

    *as_of = card_scalar(db, "SELECT strftime('" CARD_WRITTEN "', max(mtime)) FROM event WHERE type IN ('ci','f','t')");
    char *project = card_scalar(db, "SELECT value FROM config WHERE name='project-name'");
    if (project == NULL) project = sqlite3_mprintf("");

    sqlite3_stmt *stmt = NULL;
    char *sql = sqlite3_mprintf("SELECT name FROM pragma_table_info(%Q)", table);
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW && ncolumns < CARD_MAX_KEYS)
            columns[ncolumns++] = sqlite3_mprintf("%s", (const char *)sqlite3_column_text(stmt, 0));
    }
    sqlite3_finalize(stmt);
    sqlite3_free(sql);

    int none = ncolumns == 0;
    if (!none && strcmp(kind, "tickets") == 0) {
        for (int i = 0; i < nfields && !none; i++) {
            const char *f = fields[i];
            if (!card_has(columns, ncolumns, f) && strcmp(f, "time") && strcmp(f, "hash")
                && strcmp(f, "project") && strcmp(f, "user")) none = 1;
        }
    }

    char *base = NULL, *where = NULL;
    if (!none) {
        card_map_set(&source, "project", sqlite3_mprintf("%Q", project));
        if (strcmp(kind, "posts_tagged") == 0 || strcmp(kind, "threads_active_within") == 0) {
            card_map_set(&source, "title", sqlite3_mprintf("substr(e.comment, instr(e.comment, ':') + 2)"));
            card_map_set(&source, "user", sqlite3_mprintf("e.user"));
            card_map_set(&source, "time", sqlite3_mprintf("strftime('" CARD_WRITTEN_F "', f.fmtime)"));
            card_map_set(&source, "hash", sqlite3_mprintf("b.uuid"));
            if (strcmp(kind, "posts_tagged") == 0) {
                base = sqlite3_mprintf("FROM forumpost f JOIN blob b ON b.rid=f.fpid JOIN event e ON e.objid=f.fpid "
                                       "JOIN tagxref x ON x.rid=f.fpid AND x.tagtype>0 JOIN tag t ON t.tagid=x.tagid ");
                where = sqlite3_mprintf("t.tagname=%Q AND coalesce(x.value,'')=%Q", tag, value ? value : "");
                if (login) {
                    char *more = sqlite3_mprintf("%s AND NOT EXISTS (SELECT 1 FROM forumpost later JOIN event le "
                        "ON le.objid=later.fpid WHERE later.froot=f.froot AND later.fmtime>f.fmtime AND le.user=%Q)",
                        where, login);
                    sqlite3_free(where);
                    where = more;
                }
            } else {
                base = sqlite3_mprintf("FROM forumpost f JOIN blob b ON b.rid=f.fpid JOIN event e ON e.objid=f.fpid ");
                where = sqlite3_mprintf("f.fmtime=(SELECT max(n.fmtime) FROM forumpost n WHERE n.froot=f.froot) "
                    "AND f.fmtime BETWEEN julianday(strftime('" CARD_WRITTEN_F "', %Q, '-%lld seconds')) "
                    "AND julianday(strftime('" CARD_WRITTEN_F "', %Q))", now, (long long)seconds, now);
            }
        } else if (strcmp(kind, "checkins_tagged") == 0) {
            base = sqlite3_mprintf("FROM event e JOIN blob b ON b.rid=e.objid JOIN tagxref x ON x.rid=e.objid "
                                   "AND x.tagtype>0 JOIN tag t ON t.tagid=x.tagid ");
            card_map_set(&source, "title", sqlite3_mprintf("coalesce(e.ecomment,e.comment)"));
            card_map_set(&source, "user", sqlite3_mprintf("e.user"));
            card_map_set(&source, "time", sqlite3_mprintf("strftime('" CARD_WRITTEN_F "', e.mtime)"));
            card_map_set(&source, "hash", sqlite3_mprintf("b.uuid"));
            where = sqlite3_mprintf("e.type='ci' AND t.tagname=%Q", tag);
        } else {
            base = sqlite3_mprintf("FROM ticket k ");
            card_map_set(&source, "title", sqlite3_mprintf("k.title"));
            card_map_set(&source, "user", sqlite3_mprintf("''"));
            card_map_set(&source, "time", sqlite3_mprintf("strftime('" CARD_WRITTEN_F "', k.tkt_mtime)"));
            card_map_set(&source, "hash", sqlite3_mprintf("k.tkt_uuid"));
            for (int i = 0; i < ncolumns; i++)
                if (card_is_word(columns[i])) card_map_set(&source, columns[i], sqlite3_mprintf("k.%s", columns[i]));
            where = sqlite3_mprintf("k.type=%Q AND k.status NOT IN ('Closed','Fixed','Resolved')", value ? value : "");
        }
        for (int i = 0; i < nfields; i++) if (card_map_get(&source, fields[i]) == NULL) none = 1;
    }

    if (none) {
        out = sqlite3_mprintf("[]");
    } else {
        /* shown: the fields, then project, title, time and hash, each once */
        static const char *const extra[] = {"project", "title", "time", "hash"};
        char *shown[CARD_MAX_KEYS + 4];
        int nshown = 0;
        for (int i = 0; i < nfields; i++)
            if (!card_has(shown, nshown, fields[i])) shown[nshown++] = fields[i];
        for (int i = 0; i < 4; i++)
            if (!card_has(shown, nshown, extra[i])) shown[nshown++] = (char *)extra[i];
        sqlite3_str *pairs = sqlite3_str_new(NULL);
        for (int i = 0; i < nshown; i++)
            sqlite3_str_appendf(pairs, "%s%Q, coalesce(CAST(%s AS TEXT),'')", i ? "," : "",
                                shown[i], card_map_get(&source, shown[i]));
        char *p = sqlite3_str_finish(pairs);
        char *q = sqlite3_mprintf("SELECT json_group_array(json(item)) FROM "
                                  "(SELECT json_object(%s) AS item %s WHERE %s)", p, base, where);
        out = card_scalar(db, q);
        sqlite3_free(p);
        sqlite3_free(q);
    }

    sqlite3_free(base);
    sqlite3_free(where);
    sqlite3_free(project);
    card_map_free(&source);
    for (int i = 0; i < ncolumns; i++) sqlite3_free(columns[i]);
    sqlite3_close(db);
    return out;
}

/* Run `sql` on w with up to four bound texts (NULL binds NULL). */
static int card_exec(sqlite3 *w, const char *sql, const char *a, const char *b, const char *c, const char *d) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(w, sql, -1, &stmt, NULL) != SQLITE_OK) return -1;
    const char *args[4] = {a, b, c, d};
    for (int i = 0; i < 4 && i < sqlite3_bind_parameter_count(stmt); i++)
        if (args[i]) sqlite3_bind_text(stmt, i + 1, args[i], -1, SQLITE_STATIC);
    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {}
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE ? 0 : -1;
}

/* Like card_exec, returning the first column of the first row. */
static char *card_value(sqlite3 *w, const char *sql, const char *a, const char *b) {
    sqlite3_stmt *stmt = NULL;
    char *out = NULL;
    if (sqlite3_prepare_v2(w, sql, -1, &stmt, NULL) != SQLITE_OK) return NULL;
    if (a && sqlite3_bind_parameter_count(stmt) >= 1) sqlite3_bind_text(stmt, 1, a, -1, SQLITE_STATIC);
    if (b && sqlite3_bind_parameter_count(stmt) >= 2) sqlite3_bind_text(stmt, 2, b, -1, SQLITE_STATIC);
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL)
        out = sqlite3_mprintf("%s", (const char *)sqlite3_column_text(stmt, 0));
    sqlite3_finalize(stmt);
    return out;
}

int stone_fossil_card(const char *const repo_paths[], int repo_count, const char *name,
                      const char *definition_json, const char *viewer, const char *now,
                      char **out_json) {
    if (repo_paths == NULL || repo_count < 0 || name == NULL || definition_json == NULL
        || viewer == NULL || now == NULL || out_json == NULL) return -1;
    *out_json = NULL;

    sqlite3 *w = NULL;
    if (sqlite3_open_v2(":memory:", &w, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (w) sqlite3_close(w);
        return -1;
    }
    int rc = -2;
    const char *def = definition_json;
    char *fields[CARD_MAX_KEYS];
    int nfields = 0;
    char *title = card_def(w, def, "$.title", "text");
    char *fields_json = card_def(w, def, "$.fields", "array");
    char *order = card_def(w, def, "$.order", "text");
    char *limit = card_def(w, def, "$.limit", "integer");
    char *say = card_def(w, def, "$.say", "text");
    char *say_none = card_def(w, def, "$.say_none", "text");
    char *posts = card_def(w, def, "$.find.posts_tagged", "text");
    char *checkins = card_def(w, def, "$.find.checkins_tagged", "text");
    char *tickets = card_def(w, def, "$.find.tickets", "object");
    char *ttype = card_def(w, def, "$.find.tickets.type", "text");
    char *topen = card_def(w, def, "$.find.tickets.open", "boolean");
    char *within = card_def(w, def, "$.find.threads_active_within", "integer");
    char *value = card_def(w, def, "$.find.value", "text");
    char *unanswered = card_def(w, def, "$.find.unanswered_by", "text");
    char *as_of = NULL, *items = NULL, *sentence = NULL;

    int kinds = (posts != NULL) + (checkins != NULL) + (tickets != NULL) + (within != NULL);
    if (title == NULL || fields_json == NULL || order == NULL || limit == NULL || say == NULL
        || say_none == NULL || kinds != 1 || (tickets && (ttype == NULL || topen == NULL)))
        goto done;

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(w, "SELECT value, type FROM json_each(?1)", -1, &stmt, NULL) != SQLITE_OK) goto done;
    sqlite3_bind_text(stmt, 1, fields_json, -1, SQLITE_STATIC);
    int bad = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        if (strcmp((const char *)sqlite3_column_text(stmt, 1), "text") != 0 || nfields == CARD_MAX_KEYS) { bad = 1; break; }
        fields[nfields++] = sqlite3_mprintf("%s", (const char *)sqlite3_column_text(stmt, 0));
    }
    sqlite3_finalize(stmt);
    if (bad) goto done;

    rc = -1;
    const char *kind = posts ? "posts_tagged" : checkins ? "checkins_tagged" : tickets ? "tickets" : "threads_active_within";
    const char *find_value = value ? (strcmp(value, "$viewer") == 0 ? viewer : value) : (tickets ? ttype : NULL);
    const char *login = unanswered ? (strcmp(unanswered, "$viewer") == 0 ? viewer : unanswered) : NULL;
    sqlite3_int64 seconds = within ? (sqlite3_int64)strtoll(within, NULL, 10) : 0;

    if (card_exec(w, "CREATE TEMP TABLE item(j TEXT)", NULL, NULL, NULL, NULL) != 0) goto done;
    for (int i = 0; i < repo_count; i++) {
        char *repo_as_of = NULL;
        char *rows = card_repo_rows(repo_paths[i], kind, posts ? posts : checkins, find_value, login,
                                    seconds, now, fields, nfields, &repo_as_of);
        if (rows == NULL) { sqlite3_free(repo_as_of); goto done; }
        int ok = card_exec(w, "INSERT INTO item SELECT value FROM json_each(?1)", rows, NULL, NULL, NULL);
        sqlite3_free(rows);
        if (repo_as_of && (as_of == NULL || strcmp(repo_as_of, as_of) > 0)) {
            sqlite3_free(as_of);
            as_of = repo_as_of;
        } else {
            sqlite3_free(repo_as_of);
        }
        if (ok != 0) goto done;
    }

    const char *dir = strcmp(order, "newest") == 0 ? "DESC" : "ASC";
    char *sel = sqlite3_mprintf("CREATE TEMP TABLE sel AS SELECT j FROM item ORDER BY "
        "json_extract(j,'$.time') %s, json_extract(j,'$.hash') %s, json_extract(j,'$.project') %s "
        "LIMIT max(%s, 0)", dir, dir, dir, limit);
    int ok = card_exec(w, sel, NULL, NULL, NULL, NULL);
    sqlite3_free(sel);
    if (ok != 0) goto done;
    char *count = card_value(w, "SELECT count(*) FROM item", NULL, NULL);
    items = card_value(w, "SELECT json_group_array(json(x)) FROM (SELECT (SELECT json_group_object(key, value) "
        "FROM json_each(s.j) WHERE key IN (SELECT value FROM json_each(?1)) OR key = 'project') AS x "
        "FROM sel s ORDER BY s.rowid)", fields_json, NULL);
    char *first = card_value(w, "SELECT j FROM sel ORDER BY rowid LIMIT 1", NULL, NULL);
    if (count == NULL || items == NULL) { sqlite3_free(count); sqlite3_free(first); goto done; }

    if (first == NULL) {
        sentence = sqlite3_mprintf("%s", say_none);
    } else {
        /* {count}, {titles} joined by "; ", and {FIELD} of the first item,
         * whose own keys win, as OCX merges them; anything else is left. */
        sqlite3_str *s = sqlite3_str_new(NULL);
        for (const char *p = say; *p; ) {
            const char *q = p + 1;
            if (*p == '{') while ((*q >= 'a' && *q <= 'z') || *q == '_') q++;
            if (*p == '{' && q > p + 1 && *q == '}') {
                char *key = sqlite3_mprintf("%.*s", (int)(q - p - 1), p + 1);
                char *path = sqlite3_mprintf("$.\"%s\"", key);
                char *v = card_value(w, "SELECT CASE WHEN json_type(?1, ?2) IS NOT NULL "
                                        "THEN CAST(json_extract(?1, ?2) AS TEXT) END", first, path);
                if (v == NULL && strcmp(key, "count") == 0) v = sqlite3_mprintf("%s", count);
                if (v == NULL && strcmp(key, "titles") == 0)
                    v = card_value(w, "SELECT coalesce(group_concat(t, '; '), '') FROM (SELECT "
                                      "coalesce(json_extract(j,'$.title'),'') AS t FROM sel ORDER BY rowid)", NULL, NULL);
                if (v) sqlite3_str_appendall(s, v);
                else sqlite3_str_append(s, p, (int)(q - p + 1));
                sqlite3_free(v);
                sqlite3_free(path);
                sqlite3_free(key);
                p = q + 1;
            } else {
                sqlite3_str_append(s, p, 1);
                p++;
            }
        }
        sentence = sqlite3_str_finish(s);
    }

    sqlite3_stmt *o = NULL;
    if (sentence && sqlite3_prepare_v2(w, "SELECT json_object('name', ?1, 'title', ?2, 'as_of', ?3, "
            "'count', CAST(?4 AS INTEGER), 'say', ?5, 'items', json(?6))", -1, &o, NULL) == SQLITE_OK) {
        sqlite3_bind_text(o, 1, name, -1, SQLITE_STATIC);
        sqlite3_bind_text(o, 2, title, -1, SQLITE_STATIC);
        if (as_of) sqlite3_bind_text(o, 3, as_of, -1, SQLITE_STATIC);
        sqlite3_bind_text(o, 4, count, -1, SQLITE_STATIC);
        sqlite3_bind_text(o, 5, sentence, -1, SQLITE_STATIC);
        sqlite3_bind_text(o, 6, items, -1, SQLITE_STATIC);
        if (sqlite3_step(o) == SQLITE_ROW) {
            const char *text = (const char *)sqlite3_column_text(o, 0);
            size_t len = strlen(text) + 1;
            *out_json = (char *)malloc(len);
            if (*out_json) { memcpy(*out_json, text, len); rc = 0; }
        }
    }
    sqlite3_finalize(o);
    sqlite3_free(count);
    sqlite3_free(first);

done:
    for (int i = 0; i < nfields; i++) sqlite3_free(fields[i]);
    sqlite3_free(title); sqlite3_free(fields_json); sqlite3_free(order); sqlite3_free(limit);
    sqlite3_free(say); sqlite3_free(say_none); sqlite3_free(posts); sqlite3_free(checkins);
    sqlite3_free(tickets); sqlite3_free(ttype); sqlite3_free(topen); sqlite3_free(within);
    sqlite3_free(value); sqlite3_free(unanswered); sqlite3_free(as_of); sqlite3_free(items);
    sqlite3_free(sentence);
    sqlite3_close(w);
    return rc;
}
