/* StoneWasm.c: see StoneWasm.h. */
#include "StoneWasm.h"
#include "StoneWasmHello.h"
#include "wasm_export.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static pthread_mutex_t stone_wasm_lock = PTHREAD_MUTEX_INITIALIZER;
static int stone_wasm_ready = 0;

/* A temporary file in TMPDIR (the app's own tmp folder on iOS), already
 * unlinked, so it goes away when closed. */
static int stone_wasm_temp(void) {
    const char *dir = getenv("TMPDIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/stone-wasm-XXXXXX", dir && *dir ? dir : "/tmp");
    int fd = mkstemp(path);
    if (fd >= 0) unlink(path);
    return fd;
}

/* The whole file behind fd, NUL-terminated. */
static char *stone_wasm_slurp(int fd) {
    off_t size = lseek(fd, 0, SEEK_END);
    if (size < 0) size = 0;
    char *text = malloc((size_t)size + 1);
    if (!text) return NULL;
    lseek(fd, 0, SEEK_SET);
    size_t have = 0;
    while (have < (size_t)size) {
        ssize_t n = read(fd, text + have, (size_t)size - have);
        if (n <= 0) break;
        have += (size_t)n;
    }
    text[have] = 0;
    return text;
}

static char *stone_wasm_copy(const char *text) {
    char *copy = malloc(strlen(text) + 1);
    if (copy) strcpy(copy, text);
    return copy;
}

int stone_wasm_run(const unsigned char *module, unsigned int size,
                   const char *const env[], int envc,
                   const char *input, unsigned int input_len,
                   char **out_text, char **err_text) {
    char error[256] = "";
    int code = -1;
    int in_fd = -1, out_fd = -1, err_fd = -1;
    unsigned char *bytes = NULL;
    wasm_module_t loaded = NULL;
    wasm_module_inst_t instance = NULL;
    *out_text = NULL;
    *err_text = NULL;

    pthread_mutex_lock(&stone_wasm_lock);
    if (!stone_wasm_ready) {
        RuntimeInitArgs args;
        memset(&args, 0, sizeof args);
        args.mem_alloc_type = Alloc_With_System_Allocator;
        if (!wasm_runtime_full_init(&args)) {
            snprintf(error, sizeof error, "WAMR didn't start");
            goto done;
        }
        stone_wasm_ready = 1;
    }

    in_fd = stone_wasm_temp();
    out_fd = stone_wasm_temp();
    err_fd = stone_wasm_temp();
    if (in_fd < 0 || out_fd < 0 || err_fd < 0) {
        snprintf(error, sizeof error, "no temporary file for the module's input and output");
        goto done;
    }
    if (input_len && write(in_fd, input, input_len) != (ssize_t)input_len) {
        snprintf(error, sizeof error, "couldn't write the module's input");
        goto done;
    }
    lseek(in_fd, 0, SEEK_SET);

    /* The loader may change the bytes it's given, so it gets a copy. */
    bytes = malloc(size);
    if (!bytes) goto done;
    memcpy(bytes, module, size);
    loaded = wasm_runtime_load(bytes, size, error, sizeof error);
    if (!loaded) goto done;

    /* WASI closes the descriptors it's given, so it gets duplicates; the
     * originals stay open to read the output back. */
    char *argv[] = { "module" };
    wasm_runtime_set_wasi_args_ex(loaded, NULL, 0, NULL, 0, (const char **)env, (uint32_t)envc,
                                  argv, 1, dup(in_fd), dup(out_fd), dup(err_fd));
    instance = wasm_runtime_instantiate(loaded, 256 * 1024, 0, error, sizeof error);
    if (!instance) goto done;

    if (wasm_application_execute_main(instance, 0, NULL)) {
        code = (int)wasm_runtime_get_wasi_exit_code(instance);
    } else {
        const char *exception = wasm_runtime_get_exception(instance);
        snprintf(error, sizeof error, "%s", exception ? exception : "the module trapped");
        code = -1;
    }

done:
    if (instance) wasm_runtime_deinstantiate(instance);
    if (loaded) wasm_runtime_unload(loaded);
    free(bytes);
    if (out_fd >= 0) *out_text = stone_wasm_slurp(out_fd);
    if (error[0]) {
        *err_text = stone_wasm_copy(error);
    } else if (err_fd >= 0) {
        *err_text = stone_wasm_slurp(err_fd);
    }
    if (!*out_text) *out_text = stone_wasm_copy("");
    if (!*err_text) *err_text = stone_wasm_copy("");
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    if (err_fd >= 0) close(err_fd);
    pthread_mutex_unlock(&stone_wasm_lock);
    return code;
}

const unsigned char *stone_wasm_hello_module(unsigned int *size) {
    *size = (unsigned int)sizeof stone_wasm_hello;
    return stone_wasm_hello;
}
