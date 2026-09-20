/*
 * linux-query-driver.c -- exercises stone_fossil_query() (ticket
 * f0c612c027), the read-only bridge entry MaintainerRequestScanner now uses
 * instead of opening a .fossil file through a second, independent SQLite
 * library. Checks:
 *
 *   1. A freshly-inited repo's `ticket` table is visible (the query really
 *      runs against Fossil's own bundled SQLite, on a real .fossil file).
 *   2. Multi-column rows are separated correctly (Unit Separator 0x1F
 *      between columns) and NULL comes back as an empty field.
 *   3. Multiple rows are separated correctly (Record Separator 0x1E between
 *      rows) even when a column's own text value contains an embedded
 *      '\n' -- the reason '\n'/'\t' were rejected as delimiters in favor of
 *      0x1E/0x1F: ticket titles/comments can legitimately contain them.
 *   4. A bad query / nonexistent file returns nonzero, not a crash.
 */
#include "StoneFossil.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void expect_eq_str(const char *label, const char *got, const char *want) {
    int ok = (got != NULL && want != NULL && strcmp(got, want) == 0);
    printf("%s: %s\n", ok ? "PASS" : "FAIL", label);
    if (!ok) {
        printf("   got:  %s\n", got ? got : "(null)");
        printf("   want: %s\n", want ? want : "(null)");
        failures++;
    }
}

static void expect_eq_int(const char *label, int got, int want) {
    int ok = (got == want);
    printf("%s: %s (got %d, want %d)\n", ok ? "PASS" : "FAIL", label, got, want);
    if (!ok) failures++;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <workdir>\n", argv[0]);
        return 2;
    }
    const char *workdir = argv[1];
    char repo_path[4096];
    snprintf(repo_path, sizeof(repo_path), "%s/query-test.fossil", workdir);

    {
        char *out = NULL;
        const char *init_argv[] = {"init", repo_path};
        int rc = stone_fossil_run(2, init_argv, &out);
        printf("== init -> rc=%d ==\n%s\n", rc, out ? out : "");
        free(out);
        if (rc != 0) return 1;
    }

    /* 1. The ticket table exists on a stock init. */
    {
        char *out = NULL;
        int rc = stone_fossil_query(repo_path,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='ticket'", &out);
        expect_eq_int("query ticket table exists: rc", rc, 0);
        expect_eq_str("query ticket table exists: rows", out, "ticket\x1E");
        free(out);
    }

    /* 2. Multi-column rows: Unit Separator between columns, NULL -> "". */
    {
        char *out = NULL;
        int rc = stone_fossil_query(repo_path, "SELECT 'a', NULL, 'c'", &out);
        expect_eq_int("multi-column row: rc", rc, 0);
        expect_eq_str("multi-column row: fields", out, "a\x1F" "\x1F" "c\x1E");
        free(out);
    }

    /* 3. Multiple rows, one column value containing an embedded '\n' --
     * must not be mistaken for a row boundary. */
    {
        char *out = NULL;
        int rc = stone_fossil_query(workdir[0] ? repo_path : repo_path,
            "SELECT 'line1' || char(10) || 'line2' UNION ALL SELECT 'second row'", &out);
        expect_eq_int("embedded newline: rc", rc, 0);
        expect_eq_str("embedded newline: rows", out, "line1\nline2\x1Esecond row\x1E");
        free(out);
    }

    /* 4. Bad query fails cleanly (nonzero, no crash, out_text untouched). */
    {
        char *out = (char *)0x1; /* sentinel: must be reset to NULL on failure */
        int rc = stone_fossil_query(repo_path, "SELECT * FROM no_such_table", &out);
        expect_eq_int("bad query: rc is nonzero", rc != 0, 1);
        expect_eq_int("bad query: out_text reset to NULL", out == NULL, 1);
    }

    /* 5. Nonexistent file fails cleanly. */
    {
        char *out = (char *)0x1;
        int rc = stone_fossil_query("/nonexistent/path.fossil", "SELECT 1", &out);
        expect_eq_int("bad path: rc is nonzero", rc != 0, 1);
        expect_eq_int("bad path: out_text reset to NULL", out == NULL, 1);
    }

    if (failures == 0) {
        printf("\nALL PASS\n");
        return 0;
    }
    printf("\n%d FAILURE(S)\n", failures);
    return 1;
}
