#ifndef STONE_WASM_H
#define STONE_WASM_H

/*
 * StoneWasm: runs a WebAssembly (wasm32-wasi) module the way a web server
 * runs a CGI program: one module instance per request, with the request's
 * environment and body in, and its output (headers, a blank line, then the
 * page) out. The interpreter is WAMR (WebAssembly Micro Runtime), built in
 * with its fast interpreter only: iOS allows an app no JIT.
 *
 * Stone Media plugin plan (stone-media BACKLOG.md, "The steps now", step 1;
 * stone forum d584e578b6). A module asks the app for what WASI can't do
 * through imports of module `console_host`, the contract of ocx-console's
 * src/console/host.cr: fossil, query, projects, fetch, media, each taking
 * a JSON request (pointer, size) and returning the JSON reply's size, then
 * reply(buffer, size) copies the reply. The app answers them (host below).
 */

/* Answers one import: name is fossil, query, projects, fetch or media;
 * request is NUL-terminated JSON. Returns the JSON reply, malloc'd and
 * NUL-terminated (StoneWasm frees it), or NULL for "not answered". Called
 * on the thread running the module. */
typedef char *(*stone_wasm_host_fn)(void *context, const char *name, const char *request);

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

/* As stone_wasm_run, with the module's imports answered by host, which is
 * given context with each call. */
int stone_wasm_run_hosted(const unsigned char *module, unsigned int size,
                          const char *const env[], int envc,
                          const char *input, unsigned int input_len,
                          stone_wasm_host_fn host, void *context,
                          char **out_text, char **err_text);

/* The test module shipped in the app (StoneWasmHello.h): it writes a small
 * CGI response. Sets *size; the bytes are static. */
const unsigned char *stone_wasm_hello_module(unsigned int *size);

#endif
