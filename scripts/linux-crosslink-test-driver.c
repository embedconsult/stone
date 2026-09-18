/*
 * linux-crosslink-test-driver.c -- regression reproduction for ticket
 * 3a4b6c6bb8 (SIGABRT in manifest_crosslink_begin on the phone's second
 * sync of a session).
 *
 * Links the same StoneFossil.c shim the iOS app embeds against a native
 * Linux build of the vendored Fossil core (see scripts/linux-crosslink-
 * test.sh), so this runs the real embedded-reentry code path, not a
 * simulation of it.
 *
 * db_open_repository(), manifest_crosslink_begin(), and db_force_rollback()
 * are ordinary (non-static) Fossil functions, declared here the same way
 * StoneFossil.c itself declares fossil_main() -- no header for them exists
 * outside Fossil's own generated makeheaders output, which this driver
 * doesn't link against.
 */
#include "StoneFossil.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void db_open_repository(const char *zDbName);
extern void manifest_crosslink_begin(void);
extern void db_force_rollback(void);
extern void manifest_reset_state(void);
extern void db_reset_delete_on_fail(void);

static int run_cmd(const char *label, int argc, const char *const argv[]) {
    char *out = NULL;
    int rc = stone_fossil_run(argc, argv, &out);
    printf("== %s -> rc=%d ==\n%s\n", label, rc, out ? out : "(no output)");
    free(out);
    return rc;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <workdir>\n", argv[0]);
        return 2;
    }

    char repo[1024];
    snprintf(repo, sizeof(repo), "%s/leak.fossil", argv[1]);

    {
        const char *a[] = {"init", repo};
        if (run_cmd("init", 2, a) != 0) return 1;
    }

    /*
     * Simulate a SECOND invocation ("configuration pull", in the real
     * crash) that begins crosslinking and then fails via fossil_fatal()
     * mid-pass, all inside this one process -- without a live server to
     * trigger a real permission-denial fossil_fatal. Two steps:
     *
     * 1. Call the exact resets scripts/fossil-inprocess.patch wires into
     *    the top of fossil_main() (manifest_reset_state(),
     *    db_reset_delete_on_fail()) directly -- standing in for "this
     *    invocation just started", clearing whatever invocation 1 (init,
     *    above) left behind (init registers its new file with
     *    db_delete_on_failure(); see db_reset_delete_on_fail()'s doc).
     *    Skipping this step would make step 2 delete the very
     *    repository this test just created, for a reason unrelated to
     *    this test -- a real, independent bug this same investigation
     *    found, not the one this test's assertion is about.
     * 2. Open the repo, begin a crosslink pass, then unwind via the
     *    exact cleanup fossil_fatal() itself runs (db_force_rollback ->
     *    db_close) -- but WITHOUT the paired manifest_crosslink_end().
     *    That pairing gap is exactly what leaves manifest_crosslink_busy
     *    (and the other two statics manifest_reset_state() resets) set
     *    for the NEXT invocation; upstream Fossil never needs to clear
     *    it because the process exits right after.
     */
    manifest_reset_state();
    db_reset_delete_on_fail();
    db_open_repository(repo);
    manifest_crosslink_begin();
    db_force_rollback();

    /*
     * The next invocation to run any command that itself calls
     * manifest_crosslink_begin() is where the real app aborted --
     * "rebuild" is a fully local, offline one that exercises the same
     * assert. Without scripts/fossil-inprocess.patch's manifest_reset_state()
     * wired into the top of fossil_main() (src/main.c), this SIGABRTs the
     * whole process right here, the same class of crash the maintainer hit.
     */
    {
        const char *a[] = {"rebuild", repo};
        if (run_cmd("rebuild after leak", 2, a) != 0) return 1;
    }

    /* A second, ordinary invocation afterward, so this isn't just proving
     * the reset happened to run once. */
    {
        const char *a[] = {"rebuild", repo};
        if (run_cmd("rebuild again", 2, a) != 0) return 1;
    }

    printf("PASS: two fossil_main() invocations after a leaked crosslink "
           "state did not abort.\n");
    return 0;
}
