import SwiftUI
import WebKit

/// Speech editing slice 1: dictate (or type) a phrase, POST it to
/// gp-crystal's `/edit` route as the logged-in user, and show the returned
/// result text. Rendering the applied edit's blocks natively is a later
/// slice — this view shows the textual result and links out to the served
/// page for the visual.
struct GpcrEditView: View {
    let repo: Repo

    @StateObject private var recognizer = PhraseRecognizer()
    @State private var phrase = ""
    @State private var micAuthorized = false
    @State private var sending = false
    @State private var result: GpcrEditClient.Result?
    @State private var errorText: String?
    @State private var showingServedPage = false

    var body: some View {
        Form {
            Section("Phrase") {
                TextField("wrap block 1 with repeat block 2 set 3 seconds",
                          text: $phrase, axis: .vertical)
                    .lineLimit(1...4)
                    .disabled(recognizer.isRecording)

                HStack {
                    Button {
                        Task { await toggleRecording() }
                    } label: {
                        Label(recognizer.isRecording ? "Stop" : "Dictate",
                              systemImage: recognizer.isRecording ? "mic.fill" : "mic")
                    }
                    .tint(recognizer.isRecording ? .red : .accentColor)

                    Spacer()

                    Button("Send") {
                        Task { await send() }
                    }
                    .disabled(sending || !canSend)
                }

                if recognizer.isRecording, !recognizer.partialText.isEmpty {
                    Text(recognizer.partialText).foregroundStyle(.secondary)
                }
                if recognizer.isRecording {
                    Text("Tap Stop to finish dictation before sending.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if let recognizerError = recognizer.errorText {
                    Text(recognizerError).foregroundStyle(.red).font(.caption)
                }
            }

            if repo.remoteURL == nil {
                Section {
                    Text("This repository has no remote configured — add one before editing by phrase.")
                        .foregroundStyle(.secondary)
                }
            }

            if sending {
                Section { ProgressView("Sending…") }
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }

            if let result {
                Section("Result") {
                    Text(result.text)
                        .textSelection(.enabled)
                    Button("View served page") { showingServedPage = true }
                }
            }
        }
        .navigationTitle("Speak an Edit")
        .navigationBarTitleDisplayMode(.inline)
        .task { micAuthorized = await recognizer.requestAuthorization() }
        .onDisappear { recognizer.stop() }
        .sheet(isPresented: $showingServedPage) {
            if let result {
                NavigationStack {
                    GpcrResultPageView(html: result.html, baseURL: remoteBaseURL)
                        .navigationTitle("gp-crystal /edit")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingServedPage = false }
                            }
                        }
                }
            }
        }
    }

    private var canSend: Bool {
        !recognizer.isRecording
            && repo.remoteURL != nil
            && !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The repo's remote, stripped of userinfo, so the result preview's
    /// relative links/assets resolve against the right host.
    private var remoteBaseURL: URL? {
        guard let remoteURL = repo.remoteURL, var comps = URLComponents(string: remoteURL) else { return nil }
        comps.user = nil
        comps.password = nil
        return comps.url
    }

    private func toggleRecording() async {
        if recognizer.isRecording {
            recognizer.stop()
            phrase = recognizer.partialText
            return
        }
        if !micAuthorized {
            micAuthorized = await recognizer.requestAuthorization()
        }
        guard micAuthorized else {
            errorText = "Microphone or speech recognition permission was denied."
            return
        }
        recognizer.start()
    }

    private func send() async {
        guard let remoteURL = repo.remoteURL,
              let session = RemoteSession(remoteURL: remoteURL, password: CredentialStore.password(for: repo.id))
        else {
            errorText = "This repository has no remote configured."
            return
        }
        sending = true
        errorText = nil
        result = nil
        defer { sending = false }
        do {
            let client = GpcrEditClient(session: session)
            result = try await client.send(phrase: phrase)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Renders the raw HTML gp-crystal's `/edit` route returned, for visual
/// review. Slice 1 does not render blocks natively — this is the "served
/// page link" that suffices for now.
private struct GpcrResultPageView: UIViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
