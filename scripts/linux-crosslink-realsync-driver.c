/*
 * linux-crosslink-realsync-driver.c -- reproduces ticket 3a4b6c6bb8 using
 * the REAL "sync" command against a real Fossil server, not a synthetic
 * direct call into manifest.c (see linux-crosslink-test-driver.c for that
 * narrower, mechanism-level test).
 *
 * Takes the SERVER as a separate, already-running process (see
 * linux-crosslink-server-helper.c and that file's doc for why this can't
 * be the same process as this client -- StoneFossil.c's single
 * non-recursive g_fossil_lock deadlocks a client syncing against a server
 * hosted in the same process).
 *
 * Sequence: from a fresh "client" repo, run a plain `sync` against the
 * server with a WRONG password (a login failure -- the most legitimate,
 * deterministic, offline way to make client_sync's server round-trip come
 * back negative), then two more `sync`s with the CORRECT password. None
 * of the three should abort the process, regardless of the first one's
 * login outcome.
 */
#include "StoneFossil.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int run_cmd(const char *label, int argc, const char *const argv[]) {
    char *out = NULL;
    int rc = stone_fossil_run(argc, argv, &out);
    printf("== %s -> rc=%d ==\n%s\n", label, rc, out ? out : "(no output)");
    free(out);
    return rc;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <workdir> <server-port>\n", argv[0]);
        return 2;
    }
    const char *port = argv[2];

    char client_repo[1024];
    snprintf(client_repo, sizeof(client_repo), "%s/client.fossil", argv[1]);

    if (run_cmd("init client", 2, (const char *[]){"init", client_repo}) != 0) return 1;

    char bad_url[256], good_url[256];
    snprintf(bad_url, sizeof(bad_url), "http://stone:wrongpassword@127.0.0.1:%s/", port);
    snprintf(good_url, sizeof(good_url), "http://stone:correcthorse@127.0.0.1:%s/", port);

    /* This is expected to fail (login rejected) -- what matters is
     * whether it takes the WHOLE PROCESS down with it. */
    {
        const char *a[] = {"sync", bad_url, "-R", client_repo};
        run_cmd("sync with wrong password", 4, a);
    }

    /* The real assertion: a second, unrelated sync -- this time with the
     * right password -- must still be able to crosslink normally. Without
     * scripts/fossil-inprocess.patch's fix, this is where a leaked
     * manifest_crosslink_busy (from the first sync exiting abnormally)
     * would SIGABRT the whole process. */
    {
        const char *a[] = {"sync", good_url, "-R", client_repo};
        if (run_cmd("sync with correct password", 4, a) != 0) return 1;
    }

    /* And a third, to be sure. */
    {
        const char *a[] = {"sync", good_url, "-R", client_repo};
        if (run_cmd("sync again", 4, a) != 0) return 1;
    }

    printf("PASS: real sync commands (one with a bad login) did not abort "
           "the process.\n");
    return 0;
}
