#ifndef STONE_WASM_H
#define STONE_WASM_H

/*
 * StoneWasm: runs a WebAssembly (wasm32-wasi) module the way a web server
 * runs a CGI program: one module instance per request, with the request's
 * environment and body in, and its output (headers, a blank line, then the
 * page) out. The interpreter is WAMR (WebAssembly Micro Runtime), built in
 * with its fast interpreter only: iOS allows an app no JIT.
 *
 * This is step 1a of the Stone Media plugin plan (stone-media BACKLOG.md,
 * "The steps now", step 1; stone forum d584e578b6): it proves WAMR builds
 * and runs on iOS with a small module shipped inside the app. Host imports
 * (fossil, query, fetch, media) and loading a plugin from a repository come
 * in 1b.
 */

/* Runs `module` (size bytes) once. env holds envc "NAME=VALUE" strings
 * (the CGI variables); input (input_len bytes) is its stdin. On return,
 * *out_text holds what it wrote to stdout and *err_text what it wrote to
 * stderr or WAMR's error, both malloc'd and NUL-terminated, for the caller
 * to free. Returns the module's exit code, or -1 if it couldn't be loaded
 * or trapped. Calls are serialized; any thread may call. */
int stone_wasm_run(const unsigned char *module, unsigned int size,
                   const char *const env[], int envc,
                   const char *input, unsigned int input_len,
                   char **out_text, char **err_text);

/* The test module shipped in the app (StoneWasmHello.h): it writes a small
 * CGI response. Sets *size; the bytes are static. */
const unsigned char *stone_wasm_hello_module(unsigned int *size);

#endif
