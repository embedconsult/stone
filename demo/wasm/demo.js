// Loads add.wasm (one exported function, add(a, b)) and shows "wasm ok"
// when it answers 2 + 3 = 5, or the reason it couldn't. A file of its own,
// not an inline <script>: Fossil's security policy only runs scripts
// served from the repo.
(function () {
  var result = document.getElementById("result");
  var detail = document.getElementById("detail");

  function show(text, why) {
    result.textContent = text;
    detail.textContent = why || "";
  }

  if (typeof WebAssembly !== "object") {
    show("No WebAssembly", "This browser has no WebAssembly support.");
    return;
  }
  show("Loading…");

  fetch("add.wasm")
    .then(function (response) {
      if (!response.ok) throw new Error("add.wasm: HTTP " + response.status);
      return response.arrayBuffer();
    })
    .then(function (bytes) { return WebAssembly.instantiate(bytes); })
    .then(function (module) {
      var sum = module.instance.exports.add(2, 3);
      if (sum === 5) {
        show("wasm ok", "add(2, 3) = 5");
      } else {
        show("Wrong answer", "add(2, 3) = " + sum);
      }
    })
    .catch(function (error) {
      var why = String(error);
      if (/unsafe-eval|Content Security Policy|CSP|Refused/i.test(why)) {
        why += "\n\nThe repo's security policy blocks WebAssembly. " +
               "Add 'wasm-unsafe-eval' to default-csp (see README.md).";
      }
      show("wasm blocked", why);
    });
})();
