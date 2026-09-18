/*
 * linux-crosslink-server-helper.c -- starts the StoneFossil embedded
 * loopback server on a repo in its OWN process and prints the chosen port
 * on stdout, then waits for SIGTERM.
 *
 * Needed as a SEPARATE process, not just another thread/call in the same
 * process as linux-crosslink-realsync-driver.c's client: StoneFossil.c
 * serializes every embedded Fossil invocation behind one single,
 * non-recursive mutex (g_fossil_lock). A client `sync` call already holds
 * that lock for its entire duration while it blocks on the HTTP round
 * trip; if the "server" were the SAME process, handling that very
 * request needs the SAME lock and can never acquire it -- a guaranteed
 * deadlock that has nothing to do with ticket 3a4b6c6bb8's actual bug.
 * Real Stone never hits this (the remote is a genuinely separate
 * process/host); it's purely an artifact of trying to be both ends of a
 * sync in one test binary.
 */
#include "StoneFossil.h"

#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <repo.fossil>\n", argv[0]);
        return 2;
    }
    int port = 0;
    if (stone_fossil_server_start(argv[1], &port) != 0) {
        fprintf(stderr, "failed to start server\n");
        return 1;
    }
    printf("%d\n", port);
    fflush(stdout);

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    while (!g_stop) pause();

    stone_fossil_server_stop();
    return 0;
}
