/* Runs a plugin (argv[1], a .wasm file) through StoneWasm with stand-in
 * answers to its imports: fetch returns the file argv[2] as a feed, query
 * returns no rows, fossil succeeds, media says playing. Every call is
 * printed. It runs GET, then a POST importing a feed. Built and checked by
 * scripts/linux-wasm-test.cr. */
#include "StoneWasm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *slurp(const char *path, unsigned int *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *data = malloc((size_t)n + 1);
    if (fread(data, 1, (size_t)n, f) != (size_t)n) exit(2);
    data[n] = 0;
    fclose(f);
    *size = (unsigned int)n;
    return data;
}

static char *json_string(const char *text) {
    char *out = malloc(strlen(text) * 6 + 3), *o = out;
    *o++ = '"';
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p == '"' || *p == '\\') { *o++ = '\\'; *o++ = (char)*p; }
        else if (*p == '\n') { *o++ = '\\'; *o++ = 'n'; }
        else if (*p < 0x20) { o += sprintf(o, "\\u%04x", *p); }
        else *o++ = (char)*p;
    }
    *o++ = '"';
    *o = 0;
    return out;
}

static char *answer(void *context, const char *name, const char *request) {
    const char *feed = context;
    fprintf(stderr, "call %s %.200s\n", name, request);
    char *reply = malloc(strlen(feed) * 6 + 256);
    if (!strcmp(name, "fetch")) {
        char *body = json_string(feed);
        sprintf(reply, "{\"status\":200,\"type\":\"application/rss+xml\",\"body\":%s}", body);
        free(body);
    } else if (!strcmp(name, "query")) {
        strcpy(reply, "{\"rows\":[]}");
    } else if (!strcmp(name, "fossil")) {
        strcpy(reply, "{\"status\":0,\"output\":\"\",\"error\":\"\"}");
    } else if (!strcmp(name, "media")) {
        strcpy(reply, "{\"state\":\"playing\",\"title\":\"test\",\"position\":0,\"duration\":0}");
    } else {
        free(reply);
        return NULL;
    }
    return reply;
}

static int run(const unsigned char *module, unsigned int size, const char *method, const char *body, char *feed) {
    char length[64];
    snprintf(length, sizeof length, "CONTENT_LENGTH=%zu", strlen(body));
    char methodvar[64];
    snprintf(methodvar, sizeof methodvar, "REQUEST_METHOD=%s", method);
    const char *env[] = { methodvar, length, "QUERY_STRING=", "PATH_INFO=/",
                          "CONTENT_TYPE=application/x-www-form-urlencoded" };
    char *out, *err;
    int code = stone_wasm_run_hosted(module, size, env, 5, body, (unsigned int)strlen(body), answer, feed, &out, &err);
    printf("=== %s exit %d\n--- stdout\n%s\n--- stderr\n%s\n", method, code, out, err);
    free(out);
    free(err);
    return code;
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    unsigned int size, feed_size;
    unsigned char *module = (unsigned char *)slurp(argv[1], &size);
    char *feed = slurp(argv[2], &feed_size);
    if (run(module, size, "GET", "", feed) != 0) return 1;
    if (run(module, size, "POST", "do=import&url=https%3A%2F%2Fexample.com%2Ffeed.rss", feed) != 0) return 1;
    return 0;
}
