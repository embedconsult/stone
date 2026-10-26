import SwiftUI
import UserNotifications

/// The hand checks a build asks for: ios/VERIFY.md at the check-in the app
/// was built from, copied into the app by scripts/stamp-build-identity.sh.
/// Lines starting "- " are checks; a "Report:" line names the forum thread
/// (its first post's full hash) where the summary of a run is posted.
struct VerifyList: Equatable {
    var reportThread: String?
    var checks: [String]

    static func parse(_ text: String) -> VerifyList {
        var report: String?
        var checks: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("report:") {
                let value = line.dropFirst("report:".count).trimmingCharacters(in: .whitespaces)
                if value.count >= 10, value.allSatisfy(\.isHexDigit) { report = value.lowercased() }
            } else if line.hasPrefix("- ") {
                let check = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !check.isEmpty { checks.append(check) }
            }
        }
        return VerifyList(reportThread: report, checks: checks)
    }

    /// The list bundled with this build, or nil when the build has none
    /// (an Xcode build that didn't run the stamp phase).
    static var bundled: VerifyList? {
        guard let url = Bundle.main.url(forResource: "VERIFY", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }
}

/// One line of the run's result, automatic or by hand.
struct VerifyOutcome: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var passed: Bool?
    var detail: String = ""
}

/// The text recorded for a run: the `audited` tag's value and the post.
enum VerifyReport {
    enum Verdict: String {
        case pass, fail, incomplete
    }

    /// "fail" when any line failed; "pass" only when every line passed;
    /// otherwise "incomplete": nothing failed, but some hand checks were
    /// left unmarked, and the tag must not claim what nobody looked at.
    static func verdict(auto: [VerifyOutcome], hand: [VerifyOutcome]) -> Verdict {
        let all = auto + hand
        if all.contains(where: { $0.passed == false }) { return .fail }
        if all.allSatisfy({ $0.passed == true }) { return .pass }
        return .incomplete
    }

    static func summary(auto: [VerifyOutcome], hand: [VerifyOutcome]) -> String {
        let autoPassed = auto.filter { $0.passed == true }.count
        let handPassed = hand.filter { $0.passed == true }.count
        let handFailed = hand.filter { $0.passed == false }.count
        let unmarked = hand.count - handPassed - handFailed
        var text = "automatic \(autoPassed)/\(auto.count), by hand \(handPassed) passed, \(handFailed) failed"
        if unmarked > 0 { text += ", \(unmarked) not checked" }
        return text
    }

    /// Every outcome on its own line, capped so a tag stays small.
    static func details(auto: [VerifyOutcome], hand: [VerifyOutcome]) -> String {
        func line(_ o: VerifyOutcome) -> String {
            let mark = o.passed == true ? "pass" : o.passed == false ? "FAIL" : "not checked"
            return "- \(mark): \(o.name)" + (o.detail.isEmpty ? "" : " (\(o.detail))")
        }
        let text = (auto.map(line) + hand.map(line)).joined(separator: "\n")
        return text.count > 4_000 ? String(text.prefix(4_000)) + "\n…" : text
    }
}

/// One verification run's state, kept for the app's lifetime: leaving the
/// screen (to look at a repo, a conversation, Settings) must not lose the
/// automatic results or the hand marks made so far.
@MainActor
final class VerifySession: ObservableObject {
    static let shared = VerifySession()
    @Published var auto: [VerifyOutcome] = []
    @Published var hand: [VerifyOutcome] = []
    @Published var running = false
    @Published var recording = false
    @Published var resultText: String?
}

/// Verify This Build: runs the automatic checks, takes Pass or Fail on each
/// hand check from VERIFY.md, then records the run as an `audited` tag on
/// the build's own check-in (in whichever clone has it) and posts a one-line
/// summary to the thread VERIFY.md names. Both are plain Fossil artifacts
/// written to the clone and pushed by the sync that follows.
struct VerifyView: View {
    @EnvironmentObject private var store: RepoStore
    private let identity = BuildIdentity()
    private let list = VerifyList.bundled

    @ObservedObject private var session = VerifySession.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Build", value: identity.label)
                LabeledContent("Check-in", value: identity.fossilCheckin.map { String($0.prefix(12)) } ?? "unknown")
            } footer: {
                if identity.fossilCheckin == nil {
                    Text("This build doesn't say which Fossil check-in it came from, so results can be posted but not tagged.")
                }
            }

            Section("Automatic") {
                if session.auto.isEmpty && !session.running {
                    Text("Not run yet.").foregroundStyle(.secondary)
                }
                ForEach(session.auto) { outcome in
                    HStack(alignment: .top) {
                        mark(outcome.passed)
                        VStack(alignment: .leading) {
                            Text(outcome.name)
                            if !outcome.detail.isEmpty {
                                Text(outcome.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button(session.running ? "Checking…" : "Run automatic checks") {
                    Task { await runAutomatic() }
                }
                .disabled(session.running)
            }

            Section {
                if session.hand.isEmpty {
                    Text(list == nil ? "This build has no VERIFY.md." : "Nothing to check by hand for this build.")
                        .foregroundStyle(.secondary)
                }
                ForEach($session.hand) { $outcome in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(outcome.name)
                        Picker("Result", selection: $outcome.passed) {
                            Text("Not checked").tag(Bool?.none)
                            Text("Pass").tag(Bool?.some(true))
                            Text("Fail").tag(Bool?.some(false))
                        }
                        .pickerStyle(.segmented)
                        TextField("Note (optional)", text: $outcome.detail, axis: .vertical)
                            .font(.callout)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("By hand")
            }

            Section {
                Button(session.recording ? "Recording…" : "Record results") {
                    Task { await record() }
                }
                .disabled(session.recording || session.running || session.auto.isEmpty)
                if let text = session.resultText {
                    Text(text).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Adds an audited tag (pass, fail, or incomplete when some lines are left unchecked) with every line above to this build's check-in, posts a one-line summary to the thread VERIFY.md names, and syncs.")
            }
        }
        .navigationTitle("Verify This Build")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if session.hand.isEmpty, let list {
                session.hand = list.checks.map { VerifyOutcome(name: $0) }
            }
        }
    }

    @ViewBuilder
    private func mark(_ passed: Bool?) -> some View {
        switch passed {
        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case nil: ProgressView()
        }
    }

    // MARK: Automatic checks

    private func runAutomatic() async {
        session.running = true
        defer { session.running = false }
        session.auto = []

        let version = await FossilEngine.shared.run(["version"])
        session.auto.append(VerifyOutcome(name: "Fossil runs", passed: version.succeeded,
                                  detail: version.output.trimmingCharacters(in: .whitespacesAndNewlines)))

        for repo in store.repos {
            let path = store.fileURL(for: repo).path
            let rows = await Task.detached { FossilQuery.rows(path, "SELECT count(*) FROM blob") }.value
            let count = rows.first?.first ?? ""
            session.auto.append(VerifyOutcome(name: "\(repo.name) opens", passed: !count.isEmpty,
                                      detail: count.isEmpty ? "couldn't read the clone" : "\(count) artifacts"))
        }

        for repo in store.repos {
            guard let remote = repo.remoteURL, var parts = URLComponents(string: remote) else { continue }
            parts.user = nil
            parts.password = nil
            var outcome = VerifyOutcome(name: "\(repo.name)'s server answers")
            if let url = parts.url {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    outcome.passed = status > 0 && status < 500
                    outcome.detail = "HTTP \(status)"
                } catch {
                    outcome.passed = false
                    outcome.detail = error.localizedDescription
                }
            } else {
                outcome.passed = false
                outcome.detail = "not a valid address"
            }
            session.auto.append(outcome)
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        session.auto.append(VerifyOutcome(name: "Notifications allowed", passed: allowed,
                                  detail: allowed ? "" : "turned off in iOS Settings, or never asked"))
    }

    // MARK: Recording

    private func record() async {
        session.recording = true
        defer { session.recording = false }
        let verdict = VerifyReport.verdict(auto: session.auto, hand: session.hand).rawValue
        let summary = VerifyReport.summary(auto: session.auto, hand: session.hand)
        let details = VerifyReport.details(auto: session.auto, hand: session.hand)
        let buildLabel = identity.label
        var done: [String] = []
        var touched: Set<UUID> = []

        // The tag: on the build's check-in, in the clone that has it.
        if let checkin = identity.fossilCheckin,
           let (repo, path, full) = await clone(containing: checkin) {
            let value = "\(verdict): Stone on the phone, build \(buildLabel): \(summary)\n\(details)"
            let result = await FossilEngine.shared.run(["tag", "add", "--user-override", ConversationStore.login(for: repo),
                                                        "audited", full, value, "-R", path])
            done.append(result.succeeded ? "Tagged \(full.prefix(10)) in \(repo.name)." : "Couldn't tag: \(result.output)")
            if result.succeeded { touched.insert(repo.id) }
        } else {
            done.append("Not tagged: no clone on this phone has this build's check-in.")
        }

        // The post: a reply to the latest post of the thread VERIFY.md names.
        if let thread = list?.reportThread,
           let (repo, path, full) = await clone(containingThread: thread) {
            let id = ConversationID(repoID: repo.id, kind: .thread, key: full)
            let body = "Verify This Build, build \(buildLabel): **\(verdict)**, \(summary)."
            if let latest = await ConversationStore.shared.posts(for: id, fossilPath: path)?.posts.last {
                do {
                    try await ConversationWriter.reply(in: id, to: nil, latest: latest,
                                                       login: ConversationStore.login(for: repo),
                                                       body: body, fossilPath: path)
                    done.append("Posted the summary in \(repo.name).")
                    touched.insert(repo.id)
                } catch {
                    done.append("Couldn't post: \(error.localizedDescription)")
                }
            }
        } else if list?.reportThread != nil {
            done.append("Not posted: no clone on this phone has the thread VERIFY.md names.")
        }

        for repo in store.repos where touched.contains(repo.id) {
            if (try? await store.sync(repo, trigger: .verify)) == nil {
                done.append("\(repo.name) didn't sync; the results will go out with its next sync.")
            }
        }
        session.resultText = done.joined(separator: "\n")
    }

    /// The clone that has check-in `prefix`, with its full hash.
    private func clone(containing prefix: String) async -> (Repo, String, String)? {
        await find("SELECT b.uuid FROM blob b JOIN event e ON e.objid = b.rid WHERE e.type = 'ci' AND b.uuid LIKE \(FossilQuery.quote(prefix + "%")) LIMIT 1")
    }

    /// The clone that has the forum thread whose first post is `prefix`.
    private func clone(containingThread prefix: String) async -> (Repo, String, String)? {
        await find("SELECT b.uuid FROM forumpost f JOIN blob b ON b.rid = f.froot WHERE f.fpid = f.froot AND b.uuid LIKE \(FossilQuery.quote(prefix + "%")) LIMIT 1")
    }

    private func find(_ sql: String) async -> (Repo, String, String)? {
        for repo in store.repos {
            let path = store.fileURL(for: repo).path
            let rows = await Task.detached { FossilQuery.rows(path, sql) }.value
            if let full = rows.first?.first, !full.isEmpty { return (repo, path, full) }
        }
        return nil
    }
}
