import SwiftUI
import WebKit

/// Hosts a `WKWebView` pointed at the in-process Fossil server, presenting
/// Fossil's own HTML UI. This is the whole point of the app's UI strategy:
/// render Fossil's real pages so there is zero drift from upstream.
struct RepoWebView: UIViewRepresentable {
    let baseURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // localhost session only
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: baseURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The server's port is stable for the app session; nothing to refresh.
    }
}

/// Wrapper screen: starts the server for a repo, then shows its web UI.
struct RepoDetailView: View {
    let repo: Repo
    @EnvironmentObject private var store: RepoStore

    @State private var baseURL: URL?
    @State private var errorText: String?
    @State private var syncing = false
    @State private var syncMessage: String?

    var body: some View {
        Group {
            if let url = baseURL {
                RepoWebView(baseURL: url)
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorText {
                ContentUnavailableView("Couldn't start Fossil",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorText))
            } else {
                ProgressView("Starting Fossil…")
            }
        }
        .navigationTitle(repo.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await runSync() }
                } label: {
                    if syncing { ProgressView() }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                .disabled(syncing || repo.remoteURL == nil)
            }
        }
        .task { await startServer() }
        .alert("Sync", isPresented: .constant(syncMessage != nil)) {
            Button("OK") { syncMessage = nil }
        } message: {
            Text(syncMessage ?? "")
        }
    }

    private func startServer() async {
        let path = store.fileURL(for: repo).path
        do {
            baseURL = try await FossilEngine.shared.startServer(repoPath: path)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runSync() async {
        syncing = true
        defer { syncing = false }
        do {
            _ = try await store.sync(repo)
            syncMessage = "Sync complete."
        } catch {
            syncMessage = error.localizedDescription
        }
    }
}
