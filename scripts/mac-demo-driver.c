/*
 * mac-demo-driver.c — minimal macOS harness for the StoneFossil shim.
 *
 * It exercises exactly the same code path the iOS app uses: start the
 * in-process loopback HTTP server on a repository, then leave it running so a
 * browser can drive Fossil's real web UI. This stands in for the SwiftUI +
 * WKWebView shell while proving the engine works.
 */

#include "StoneFossil.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <repo.fossil>\n", argv[0]);
        return 2;
    }
    const char *repo = argv[1];

    int port = 0;
    if (stone_fossil_server_start(repo, &port) != 0) {
        fprintf(stderr, "failed to start StoneFossil server\n");
        return 1;
    }

    char url[64];
    snprintf(url, sizeof(url), "http://localhost:%d/", port);
    printf("\n  Stone (Fossil) UI serving at: %s\n", url);
    printf("  Repository: %s\n", repo);
    printf("  (Open the URL above in a browser when you want to view it.)\n\n");
    fflush(stdout);

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    while (!g_stop) pause();

    printf("\nStopping server...\n");
    stone_fossil_server_stop();
    return 0;
}
