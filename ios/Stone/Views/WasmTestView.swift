import SwiftUI
import WebKit

/// Runs a WebAssembly module through StoneWasm (WAMR, built into the app):
/// once per request, with CGI variables in and a CGI response out.
enum WasmRunner {
    struct Result {
        let code: Int32
        let output: String
        let error: String

        /// The page: the output after its CGI headers.
        var body: String {
            for separator in ["\r\n\r\n", "\n\n"] {
                if let range = output.range(of: separator) { return String(output[range.upperBound...]) }
            }
            return output
        }
    }

    /// The small test module shipped in the app (StoneWasmHello.h).
    static var hello: [UInt8] {
        var size: UInt32 = 0
        guard let bytes = stone_wasm_hello_module(&size) else { return [] }
        return Array(UnsafeBufferPointer(start: bytes, count: Int(size)))
    }

    /// Runs `module` once; `host` answers its imports (PluginHost), given
    /// `context` with each call.
    static func run(_ module: [UInt8], env: [String] = [], input: String = "",
                    host: stone_wasm_host_fn? = nil, context: UnsafeMutableRawPointer? = nil) -> Result {
        let strings = env.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } }
        var out: UnsafeMutablePointer<CChar>?
        var err: UnsafeMutablePointer<CChar>?
        let code = module.withUnsafeBufferPointer { moduleBytes in
            pointers.withUnsafeBufferPointer { envp in
                input.withCString { inputChars in
                    stone_wasm_run_hosted(moduleBytes.baseAddress, UInt32(module.count), envp.baseAddress, Int32(env.count),
                                          inputChars, UInt32(input.utf8.count), host, context, &out, &err)
                }
            }
        }
        let output = out.map { String(cString: $0) } ?? ""
        let error = err.map { String(cString: $0) } ?? ""
        free(out)
        free(err)
        return Result(code: code, output: output, error: error)
    }
}

/// Settings > WebAssembly Test: runs the test module and shows its page,
/// to show WAMR works on this phone (Stone Media plugin plan, step 1a).
struct WasmTestView: View {
    @State private var page: String?
    @State private var problem: String?

    var body: some View {
        Group {
            if let page {
                HTMLPage(html: page)
            } else if let problem {
                ContentUnavailableView("The module didn't run", systemImage: "exclamationmark.triangle",
                                       description: Text(problem))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("WebAssembly Test")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let result = await Task.detached {
                WasmRunner.run(WasmRunner.hello, env: ["REQUEST_METHOD=GET", "PATH_INFO=/"])
            }.value
            if result.code == 0 {
                page = result.body
            } else {
                problem = "Exit \(result.code). \(result.error)"
            }
        }
    }
}

/// HTML shown in a web view.
private struct HTMLPage: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView { WKWebView() }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: nil)
    }
}
