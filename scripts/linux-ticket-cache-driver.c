/*
 * linux-ticket-cache-driver.c -- reproduces ticket 11018cb484 ("Sync All:
 * 1 synced, 9 failed", SQLITE_ERROR "no such column: complexity"
 * crosslinking an incoming ticket change).
 *
 * Root cause (found while investigating this ticket, not named in its own
 * brief): getAllTicketFields() in src/tkt.c reads the LOCAL ticket table's
 * real columns via PRAGMA table_info(ticket) exactly once per PROCESS (a
 * plain C static), then caches that field list for every later crosslink
 * in the same process. Stone's RepoStore.syncAll() runs one fossil_main()
 * invocation per repo in the SAME long-lived process -- so once any repo
 * with a custom column (e.g. "complexity") is processed, EVERY repo
 * processed afterward in that same run reuses that repo's field list,
 * regardless of its own actual schema. A later repo's own ticket table
 * genuinely lacking "complexity" then gets an UPDATE that names it
 * anyway, because the (wrong, stale) cache says it's a known field.
 *
 * This reproduces that with two repos and no network: repoA has a real
 * "complexity" column (set up by scripts/run-ticket-cache-test.sh via the
 * standalone host `fossil` binary) and a ticket using it; repoB has the
 * STOCK schema (no "complexity") but, via a raw blob/tag copy the setup
 * script performs, contains the SAME ticket-change artifact -- standing
 * in for "an artifact that arrived via sync from a repo with a newer
 * schema, into a clone whose local table was never rebuilt to match."
 *
 * `fossil rebuild` is a fully local command that still calls
 * manifest_crosslink_begin()/end() and processes every ticket-change
 * artifact via the same ticket_insert()/getAllTicketFields() path a real
 * sync's incoming-artifact crosslinking does -- no server needed to
 * exercise the actual bug.
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
        fprintf(stderr, "usage: %s <repoA.fossil> <repoB.fossil>\n", argv[0]);
        return 2;
    }
    const char *repoA = argv[1];
    const char *repoB = argv[2];

    /* repoA's own rebuild: its table genuinely has "complexity", so this
     * succeeds and, as a side effect, populates getAllTicketFields()'s
     * process-lifetime cache with a field list that includes it. */
    if (run_cmd("rebuild repoA (has complexity)", 2,
                (const char *[]){"rebuild", repoA}) != 0) {
        fprintf(stderr, "repoA rebuild should have succeeded -- setup problem, "
                        "not the bug under test.\n");
        return 1;
    }

    /* The real assertion: repoB's own table does NOT have "complexity".
     * Without scripts/fossil-inprocess.patch's ticket_reset_field_cache(),
     * this reuses repoA's cached field list, wrongly includes
     * "complexity" in the UPDATE, and fails with
     * "SQLITE_ERROR: no such column: complexity" -- the exact error
     * reported live. With the fix, this must succeed. */
    int rc = run_cmd("rebuild repoB (stock schema)", 2,
                     (const char *[]){"rebuild", repoB});
    if (rc != 0) {
        fprintf(stderr, "FAIL: repoB's rebuild failed -- this is ticket "
                        "11018cb484's bug.\n");
        return 1;
    }

    printf("PASS: repoB crosslinked cleanly after repoA (which has an "
           "extra ticket column) ran first in the same process.\n");
    return 0;
}
