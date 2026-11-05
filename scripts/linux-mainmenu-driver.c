/*
 * linux-mainmenu-driver.c -- each repository's pages show its own main
 * menu (stone, forum 405152d5b2: the phone's ocx-console clone showed the
 * stone repository's menu, and a changed menu never appeared).
 *
 * Cause: style_get_mainmenu() in src/style.c kept the menu in a
 * function-local static, read once per process. Fossil exits after each
 * request, so that never mattered upstream; the app serves every page
 * from one process, so the first page drawn set the menu for all later
 * pages in every repository. scripts/fossil-inprocess.patch clears it in
 * style_reset_state().
 *
 * Two repositories with different menus, served in turn through the
 * app's in-process server, and the first again after its menu changes.
 */
#include "StoneFossil.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int run(int argc, const char *const argv[]) {
    char *out = NULL;
    int rc = stone_fossil_run(argc, argv, &out);
    if (rc != 0) fprintf(stderr, "fossil %s failed: %s\n", argv[0], out ? out : "");
    free(out);
    return rc;
}

static char *get(int port, const char *path) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return NULL; }
    char req[256];
    snprintf(req, sizeof req, "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", path);
    if (write(s, req, strlen(req)) < 0) { close(s); return NULL; }
    size_t cap = 1 << 16, len = 0;
    char *buf = malloc(cap);
    ssize_t n;
    while ((n = read(s, buf + len, cap - len - 1)) > 0) {
        len += (size_t)n;
        if (cap - len < 4096) buf = realloc(buf, cap *= 2);
    }
    buf[len] = 0;
    close(s);
    return buf;
}

static int check(int port, const char *label, const char *want, const char *not_want) {
    char *page = get(port, "/timeline");
    int ok = page && strstr(page, want) && !strstr(page, not_want);
    printf("%s: %s\n", label, ok ? "own menu" : "WRONG menu");
    free(page);
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s DIR\n", argv[0]); return 2; }
    char a[1024], b[1024];
    snprintf(a, sizeof a, "%s/menu-a.fossil", argv[1]);
    snprintf(b, sizeof b, "%s/menu-b.fossil", argv[1]);
    unlink(a); unlink(b);
    if (run(2, (const char *[]){"init", a}) || run(2, (const char *[]){"init", b})) return 1;
    if (run(5, (const char *[]){"setting", "mainmenu", "Home /home * {} MenuAlpha /a * {}", "-R", a})) return 1;
    if (run(5, (const char *[]){"setting", "mainmenu", "Home /home * {} MenuBravo /b * {}", "-R", b})) return 1;

    int port = 0;
    if (stone_fossil_server_start(a, &port) != 0) { fprintf(stderr, "server didn't start\n"); return 1; }
    int ok = check(port, "first repository", "MenuAlpha", "MenuBravo");
    stone_fossil_server_set_repo(b);
    ok &= check(port, "second repository", "MenuBravo", "MenuAlpha");
    if (run(5, (const char *[]){"setting", "mainmenu", "Home /home * {} MenuCharlie /c * {}", "-R", a})) return 1;
    stone_fossil_server_set_repo(a);
    ok &= check(port, "first repository, menu changed", "MenuCharlie", "MenuAlpha");
    stone_fossil_server_stop();
    printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
