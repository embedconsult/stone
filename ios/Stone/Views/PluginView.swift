import SwiftUI
import WebKit

/// A bundled app as a page: every request the page makes, forms included,
/// runs the module once through PluginHost, and its CGI response is what
/// the web view shows.
struct PluginView: View {
    let app: PluginHost.App
    @EnvironmentObject private var store: RepoStore
    @State private var handler: PluginSchemeHandler?
    @State private var problem: String?

    var body: some View {
        Group {
            if let handler {
                PluginWebView(handler: handler)
            } else if let problem {
                ContentUnavailableView("The app didn't load", systemImage: "puzzlepiece",
                                       description: Text(problem))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(app.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { NowPlayingBar() }
        .task {
            if let module = PluginHost.module(app) {
                handler = PluginSchemeHandler(module: module, context: PluginHost.context(app, store))
            } else {
                problem = "\(app.name)'s module doesn't match its release.txt."
            }
        }
    }
}

/// Stone's apps, opened from the home screen's four squares: each bundled
/// app with the project and check-in it was built from, whether that
/// project's repository is on this phone, and its switch. An app is off
/// until switched on, and only an app that's on opens.
struct AppsView: View {
    @EnvironmentObject private var store: RepoStore

    var body: some View {
        List {
            if PluginHost.apps.isEmpty {
                Text("No apps in this build.")
            }
            ForEach(PluginHost.apps) { app in
                AppRow(app: app, repoHere: store.repos.contains {
                    ($0.fileName as NSString).deletingPathExtension == app.project
                })
            }
        }
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppRow: View {
    let app: PluginHost.App
    let repoHere: Bool
    @AppStorage private var on: Bool

    init(app: PluginHost.App, repoHere: Bool) {
        self.app = app
        self.repoHere = repoHere
        _on = AppStorage(wrappedValue: false, PluginHost.switchKey(app))
    }

    var body: some View {
        Section {
            Toggle(isOn: $on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.title).font(.headline)
                    Text("\(app.project), check-in \(String(app.checkin.prefix(10)))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(repoHere ? "Its repository is on this phone" : "Its repository isn't on this phone")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if on {
                NavigationLink {
                    PluginView(app: app)
                } label: {
                    Label("Open \(app.title)", systemImage: "puzzlepiece")
                }
            }
        }
    }
}

/// Answers the page's requests (scheme stone-plugin) by running the module.
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "stone-plugin"
    static let start = URL(string: "\(scheme)://plugin/")!

    private let module: [UInt8]
    private let context: PluginHost.Context
    private var stopped = Set<ObjectIdentifier>()

    init(module: [UInt8], context: PluginHost.Context) {
        self.module = module
        self.context = context
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let request = task.request
        let url = request.url ?? Self.start
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let id = ObjectIdentifier(task)
        Task { @MainActor in
            let result = await PluginHost.run(module, context, method: method, query: url.query ?? "",
                                              body: body, contentType: type)
            guard !stopped.contains(id) else { return }
            let (status, headers, page) = Self.response(result)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response)
            task.didReceive(page)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    /// The CGI response split into status, headers and page; a failed run
    /// becomes a page saying why.
    static func response(_ result: WasmRunner.Result) -> (Int, [String: String], Data) {
        let output = result.output
        guard result.code == 0, !output.isEmpty else {
            let why = result.error.isEmpty ? "exit \(result.code)" : result.error
            let page = "<!doctype html><meta name=\"viewport\" content=\"width=device-width\"><h3>The plugin failed</h3><pre>"
                + why.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") + "</pre>"
            return (500, ["Content-Type": "text/html; charset=utf-8"], Data(page.utf8))
        }
        var status = 200
        var headers: [String: String] = [:]
        var head = ""
        var page = output
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = output.range(of: separator) {
                head = String(output[..<range.lowerBound])
                page = String(output[range.upperBound...])
                break
            }
        }
        for line in head.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.lowercased() == "status" {
                status = Int(value.prefix(3)) ?? 200
            } else if key.lowercased() != "content-length" {
                headers[key] = value
            }
        }
        let data = Data(page.utf8)
        headers["Content-Length"] = String(data.count)
        return (status, headers, data)
    }
}

private struct PluginWebView: UIViewRepresentable {
    let handler: PluginSchemeHandler

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PluginSchemeHandler.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: PluginSchemeHandler.start))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
