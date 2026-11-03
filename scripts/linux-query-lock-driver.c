/*
 * linux-query-lock-driver.c -- runs stone_fossil_query on four threads while
 * the main thread keeps writing with Fossil itself, the way the app reads a
 * clone while a sync commits to it. Before the fix, a read landing in a COMMIT
 * failed at once, and SQLite's process-wide log put its error in the writer's
 * output, so a sync that worked was shown as failed on the phone:
 *   SQLITE_BUSY(5): database is locked in "PRAGMA table_info(ticketchng)"
 *   SQL: COMMIT
 * Exits nonzero if a write fails, if any write's output holds an SQLITE_ error,
 * or if any read fails. Half the reads are a card (stone_fossil_card), which
 * must find the one check-in tagged card-probe every time.
 * Usage: linux-query-lock-driver <scratch-repo.fossil> <seconds>. It adds tags
 * to the repository, so give it a copy.
 */
#include "StoneFossil.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char *repo;
static volatile int stop = 0;
static long reads = 0, failed_reads = 0, cards = 0, failed_cards = 0;

static const char *card_def =
    "{\"title\":\"Probe\",\"find\":{\"checkins_tagged\":\"card-probe\"},"
    "\"fields\":[\"title\",\"hash\"],\"order\":\"newest\",\"limit\":10,"
    "\"say\":\"{count}\",\"say_none\":\"none\"}";

static void *reader(void *unused) {
    (void)unused;
    while (!stop) {
        char *out = NULL;
        if (stone_fossil_query(repo, "PRAGMA table_info(ticketchng)", &out) != 0)
            __atomic_add_fetch(&failed_reads, 1, __ATOMIC_RELAXED);
        free(out);
        out = NULL;
        const char *repos[] = {repo};
        if (stone_fossil_card(repos, 1, "probe", "probe", card_def, "stone",
                              "2030-01-01T00:00:00Z", &out) != 0
            || out == NULL || strstr(out, "\"count\":1,") == NULL)
            __atomic_add_fetch(&failed_cards, 1, __ATOMIC_RELAXED);
        free(out);
        __atomic_add_fetch(&cards, 1, __ATOMIC_RELAXED);
        __atomic_add_fetch(&reads, 1, __ATOMIC_RELAXED);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s REPO SECONDS\n", argv[0]);
        return 2;
    }
    repo = argv[1];
    time_t end = time(NULL) + atoi(argv[2]);
    const char *probe[] = {"tag", "add", "--raw", "card-probe", "trunk", "-R", repo};
    char *probe_out = NULL;
    if (stone_fossil_run(7, probe, &probe_out) != 0) {
        fprintf(stderr, "could not tag card-probe: %s\n", probe_out ? probe_out : "");
        return 1;
    }
    free(probe_out);
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) pthread_create(&threads[i], NULL, reader, NULL);

    long writes = 0, failed_writes = 0, leaked = 0;
    char *sample = NULL;
    while (time(NULL) < end) {
        char name[64];
        snprintf(name, sizeof name, "lock-%ld", writes);
        const char *args[] = {"tag", "add", "--raw", name, "trunk", "-R", repo};
        char *out = NULL;
        if (stone_fossil_run(7, args, &out) != 0) failed_writes++;
        if (out != NULL && strstr(out, "SQLITE_") != NULL) {
            leaked++;
            if (sample == NULL) sample = strdup(out);
        }
        free(out);
        writes++;
    }
    stop = 1;
    for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);

    printf("writes=%ld failed=%ld with_sqlite_error=%ld reads=%ld failed=%ld cards=%ld failed=%ld\n",
           writes, failed_writes, leaked, reads, failed_reads, cards, failed_cards);
    if (sample != NULL) printf("first such output:\n%s\n", sample);
    free(sample);
    return (failed_writes || leaked || failed_reads || failed_cards || writes == 0) ? 1 : 0;
}
