/* Runs Stone's test module through StoneWasm (the same C the app builds)
 * and prints its exit code, stdout and stderr. Built and checked by
 * scripts/linux-wasm-test.cr. */
#include "StoneWasm.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    unsigned int size;
    const unsigned char *module = stone_wasm_hello_module(&size);
    const char *env[] = { "REQUEST_METHOD=GET", "PATH_INFO=/" };
    for (int round = 0; round < 3; round++) {   /* one instance per request */
        char *out, *err;
        int code = stone_wasm_run(module, size, env, 2, "", 0, &out, &err);
        printf("exit %d\n--- stdout\n%s\n--- stderr\n%s\n", code, out, err);
        free(out);
        free(err);
        if (code != 0) return 1;
    }
    return 0;
}
