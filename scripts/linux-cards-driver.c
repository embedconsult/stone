/*
 * linux-cards-driver.c -- checks stone_fossil_card() against OCX's shared
 * card examples (scripts/card-examples, from ollama 14f6af3b8e), so Stone and
 * OCX give each card the same answer. For each expected/NAME.json in the
 * example directory:
 *
 *   1. read the definition from the wiki page card/NAME in a.fossil, through
 *      the embedded Fossil (`wiki export`), as the phone reads it;
 *   2. answer it from every .fossil in the built directory, for login stone,
 *      at the time in now.txt;
 *   3. compare the answer with the expected JSON, parsed: every key, value
 *      and array position (json_tree), not the text.
 *
 * Then two definitions that aren't cards (two finds; none) must be refused.
 *
 * Usage: cards-test EXAMPLE_DIR BUILT_DIR
 */
#include "StoneFossil.h"
#include "sqlite3.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); buf = NULL; }
    if (buf) buf[n] = '\0';
    fclose(f);
    return buf;
}

static int by_name(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

/* Names in `dir` ending in `suffix` (but not ".schema.json"), sorted. */
static int list(const char *dir, const char *suffix, char *out[], int max) {
    DIR *d = opendir(dir);
    int n = 0;
    struct dirent *e;
    if (d == NULL) return 0;
    while ((e = readdir(d)) != NULL && n < max) {
        size_t len = strlen(e->d_name), sl = strlen(suffix);
        if (len <= sl || strcmp(e->d_name + len - sl, suffix) != 0) continue;
        if (len > 12 && strcmp(e->d_name + len - 12, ".schema.json") == 0) continue;
        out[n++] = strdup(e->d_name);
    }
    closedir(d);
    qsort(out, (size_t)n, sizeof(char *), by_name);
    return n;
}

/* Rows of json_tree(a) missing from json_tree(b), printed; their count. */
static int differences(sqlite3 *db, const char *a, const char *b, const char *label) {
    sqlite3_stmt *stmt = NULL;
    int n = 0;
    sqlite3_prepare_v2(db,
        "SELECT fullkey, type, atom FROM json_tree(?1) WHERE type NOT IN ('object','array') "
        "EXCEPT SELECT fullkey, type, atom FROM json_tree(?2) WHERE type NOT IN ('object','array')",
        -1, &stmt, NULL);
    sqlite3_bind_text(stmt, 1, a, -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, b, -1, SQLITE_STATIC);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        printf("    %s %s = %s\n", label, sqlite3_column_text(stmt, 0),
               sqlite3_column_text(stmt, 2) ? (const char *)sqlite3_column_text(stmt, 2) : "null");
        n++;
    }
    sqlite3_finalize(stmt);
    return n;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s EXAMPLE_DIR BUILT_DIR\n", argv[0]);
        return 2;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/now.txt", argv[1]);
    char *now = read_file(path);
    if (now == NULL) { fprintf(stderr, "no %s\n", path); return 2; }
    now[strcspn(now, "\r\n")] = '\0';

    char *names[64], *repos[64];
    const char *repo_paths[64];
    int nrepos = list(argv[2], ".fossil", repos, 64);
    for (int i = 0; i < nrepos; i++) {
        char *p = malloc(strlen(argv[2]) + strlen(repos[i]) + 2);
        sprintf(p, "%s/%s", argv[2], repos[i]);
        repo_paths[i] = p;
    }
    char definitions[4096];
    snprintf(definitions, sizeof definitions, "%s/a.fossil", argv[2]);
    snprintf(path, sizeof path, "%s/expected", argv[1]);
    int ncards = list(path, ".json", names, 64);
    if (ncards == 0 || nrepos == 0) { fprintf(stderr, "nothing to check\n"); return 2; }

    sqlite3 *db = NULL;
    sqlite3_open(":memory:", &db);

    for (int i = 0; i < ncards; i++) {
        char name[256];
        snprintf(name, sizeof name, "%.*s", (int)(strlen(names[i]) - 5), names[i]);
        char page[300];
        snprintf(page, sizeof page, "card/%s", name);
        const char *args[] = {"wiki", "export", page, "-R", definitions};
        char *definition = NULL;
        if (stone_fossil_run(5, args, &definition) != 0 || definition == NULL) {
            printf("FAIL %s: couldn't read %s\n", name, page);
            failures++;
            free(definition);
            continue;
        }
        snprintf(path, sizeof path, "%s/expected/%s", argv[1], names[i]);
        char *expected = read_file(path);
        char *answer = NULL;
        int rc = stone_fossil_card(repo_paths, nrepos, name, definition, "stone", now, &answer);
        if (rc != 0 || answer == NULL || expected == NULL) {
            printf("FAIL %s: stone_fossil_card returned %d\n", name, rc);
            failures++;
        } else {
            int n = differences(db, answer, expected, "got") + differences(db, expected, answer, "expected");
            if (n) {
                printf("FAIL %s: %d differences\n    answer: %s\n", name, n, answer);
                failures++;
            } else {
                printf("ok %s: %s\n", name, answer);
            }
        }
        free(answer);
        free(expected);
        free(definition);
    }

    const char *refused[] = {
        "{\"title\":\"t\",\"find\":{\"posts_tagged\":\"asks\",\"checkins_tagged\":\"milestone\"},"
        "\"fields\":[\"title\"],\"order\":\"newest\",\"limit\":1,\"say\":\"s\",\"say_none\":\"n\"}",
        "{\"title\":\"t\",\"find\":{},\"fields\":[\"title\"],\"order\":\"newest\",\"limit\":1,"
        "\"say\":\"s\",\"say_none\":\"n\"}",
    };
    for (int i = 0; i < 2; i++) {
        char *answer = NULL;
        int rc = stone_fossil_card(repo_paths, nrepos, "bad", refused[i], "stone", now, &answer);
        if (rc != -2) {
            printf("FAIL refused %d: returned %d\n", i, rc);
            failures++;
        } else {
            printf("ok refused %d\n", i);
        }
        free(answer);
    }

    sqlite3_close(db);
    if (failures) {
        printf("FAIL: %d card checks failed\n", failures);
        return 1;
    }
    printf("PASS: %d cards answer as OCX's examples expect\n", ncards);
    return 0;
}
