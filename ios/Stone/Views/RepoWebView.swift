import SwiftUI
import WebKit

/// Hosts a `WKWebView` pointed at the in-process Fossil server, presenting
/// Fossil's own HTML UI. This is the whole point of the app's UI strategy:
/// render Fossil's real pages so there is zero drift from upstream.
struct RepoWebView: UIViewRepresentable {
    let baseURL: URL
    var onURLChange: ((URL) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // localhost session only
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: baseURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The server's port is stable for the app session; nothing to refresh.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RepoWebView

        init(_ parent: RepoWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                parent.onURLChange?(url)
            }
        }
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
    @State private var showingGpcrEdit = false

    @State private var currentURL: URL?
    @State private var showingReplyComposer = false
    @State private var replyText = ""
    @State private var replyError: String?

    var body: some View {
        Group {
            if let url = baseURL {
                RepoWebView(baseURL: url, onURLChange: { currentURL = $0 })
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
                    showingGpcrEdit = true
                } label: {
                    Image(systemName: "mic")
                }
                .disabled(repo.remoteURL == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if let fpid = extractFPID(from: currentURL) {
                        Button {
                            showingReplyComposer = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                    Button {
                        Task { await runSync() }
                    } label: {
                        if syncing { ProgressView() }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(syncing || repo.remoteURL == nil)
                }
            }
        }
        .task { await startServer() }
        .alert("Sync", isPresented: .constant(syncMessage != nil)) {
            Button("OK") { syncMessage = nil }
        } message: {
            Text(syncMessage ?? "")
        }
        .sheet(isPresented: $showingGpcrEdit) {
            NavigationStack {
                GpcrEditView(repo: repo)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingGpcrEdit = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingReplyComposer) {
            VStack(spacing: 20) {
                Text("Reply to Thread").font(.headline)
                TextEditor(text: $replyText)
                    .frame(height: 200)
                    .border(Color.gray, width: 1)
                if let err = replyError {
                    Text(err).foregroundColor(.red).font(.caption)
                }
                HStack {
                    Button("Cancel") {
                        showingReplyComposer = false
                        replyText = ""
                        replyError = nil
                    }
                    Spacer()
                    Button("Send") {
                        Task { await sendReply() }
                    }
                    .disabled(replyText.isEmpty)
                }
            }
            .padding()
            .presentationDetents([.medium])
        }
    }

    private func extractFPID(from url: URL?) -> String? {
        guard let url = url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fpid = components.queryItems?.first(where: { $0.name == "fpid" })?.value else {
            return nil
        }
        return fpid
    }

    private func sendReply() async {
        guard let fpid = extractFPID(from: currentURL),
              let remoteURL = repo.remoteURL else { return }

        let password = CredentialStore.password(for: repo.id)
        guard let session = RemoteSession(remoteURL: remoteURL, password: password) else {
            replyError = "Invalid remote session configuration."
            return
        }

        do {
            try await session.postReply(fpid: fpid, text: replyText)
            showingReplyComposer = false
            replyText = ""
            replyError = nil
        } catch {
            replyError = error.localizedDescription
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
