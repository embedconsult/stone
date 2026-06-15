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

    int rc = invoke_fossil(full, vec, out_text);

    for (int i = 0; i < full; i++) free(vec[i]);
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
    snprintf(baseurl, sizeof(baseurl), "http://localhost:%d", g_server.port);

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

static void *accept_loop(void *arg) {
    (void)arg;
    while (g_server.running) {
        int cfd = accept(g_server.listen_fd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            break; /* listen socket closed -> shut down */
        }
        handle_connection(cfd);
        close(cfd);
    }
    return NULL;
}

int stone_fossil_server_start(const char *repo_path, int *out_port) {
    if (g_server.running) return 0; /* already up */
    if (repo_path == NULL || out_port == NULL) return -1;

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
