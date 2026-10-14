# WebAssembly in a Fossil page

A minimal check that a repo can serve WebAssembly to a browser, including
Stone's in-app web view: [index.html](index.html) loads
[demo.js](demo.js), which fetches `add.wasm` (one function, `add(a, b)`)
and shows **wasm ok** when it returns 2 + 3 = 5.

## Files

- `index.html`: the page. It has no inline script.
- `demo.js`: loads the module and reports the result, or why it failed.
- `add.wasm`: 41 bytes, hand-assembled from this text form:

      (module
        (func (export "add") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.add))

Fossil serves `.wasm` files as `application/wasm`.

## The one setting it needs

Fossil sends a Content Security Policy with every page. The default allows
the repo's own scripts but not compiling WebAssembly, so the page shows
**wasm blocked** until `script-src` also allows `'wasm-unsafe-eval'`. Set
the repo's `default-csp` setting to the default policy with that one word
added, on a single line:

    default-src 'self' data:; script-src 'self' 'nonce-$nonce' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src * data:

If the repo already has a `default-csp` of its own, add
`'wasm-unsafe-eval'` to its `script-src` part rather than replacing it.
This repo (stone) has one, which keeps a `connect-src` part. Its line with
WebAssembly allowed is:

    default-src 'self' data:; script-src 'self' 'nonce-$nonce' 'wasm-unsafe-eval'; connect-src 'self' https://ollama.openbeagle.org:8443; style-src 'self' 'unsafe-inline'; img-src * data:

**In Stone** (the phone's own copy of the repo), open this README in the
repo view, then:

1. Open [the default-csp setting](../../../../setup_settings#iddefault-csp).
   This page is the repo's Admin → Settings; the link jumps to the
   `default-csp` box. The app's built-in server gives you admin rights there.
2. Replace the box's text with the line above, and press Apply Changes at
   the bottom of the page.
3. Come back here and open [the demo](index.html).

These links are relative, so they stay on whichever copy served this page.
A link tapped in a Stone conversation goes to the server instead, whose
policy is separate. The demo says which copy served it ("this phone's own
copy" or "the server") and, when blocked, prints the policy it ran under.

**On a server** (Fossil's own pages, and Stone's Remote Site view), an admin
does the same under Admin → Settings, or runs:

    fossil set -R REPO.fossil default-csp "default-src 'self' data:; script-src 'self' 'nonce-\$nonce' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src * data:"

`default-csp` belongs to the skin settings, so a normal sync doesn't carry it
to clones. A clone that wants the server's value runs
`fossil config pull skin`.

`'wasm-unsafe-eval'` allows compiling WebAssembly and nothing else. Scripts
must still come from the repo. See Fossil's
[CSP document](https://fossil-scm.org/home/doc/trunk/www/defcsp.md).
