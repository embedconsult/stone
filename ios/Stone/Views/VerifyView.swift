import SwiftUI
import UserNotifications

/// The hand checks, read from the wiki page "Hand checks" in the phone's
/// copy of the repo the app is built from. It's data, not part of the app:
/// a wiki edit syncs to the phone and, not being a check-in, starts no build
/// (stone, 2026-10-27: "that hand check should have been data driven";
/// three of four builds had changed only the list, then ios/VERIFY.md).
/// Lines starting "- " are checks, each ending with the check-in it is for,
/// in parentheses; a "Report:" line names the forum thread (its first
/// post's full hash) where the summary of a run is posted.
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

    static let page = "Hand checks"

    /// The check-in a line is for: its last parenthesized run of hex digits,
    /// such as "(79a9936235)".
    static func checkin(of check: String) -> String? {
        guard check.hasSuffix(")"), let open = check.lastIndex(of: "(") else { return nil }
        let inside = check[check.index(after: open)..<check.index(before: check.endIndex)]
        return inside.count >= 6 && inside.allSatisfy(\.isHexDigit) ? inside.lowercased() : nil
    }

    /// The checks this build asks for: those whose check-in it includes
    /// (or that name none Stone can find), less those an `audited` tag in
    /// the same copy records as passed, so a passed line needs no removal.
    func pending(build: String?, fossilPath: String) -> [String] {
        let passed = Set(FossilQuery.rows(fossilPath,
            "SELECT value FROM tagxref JOIN tag USING(tagid) WHERE tagname = 'sym-audited' AND value IS NOT NULL")
            .compactMap(\.first)
            .flatMap { $0.components(separatedBy: "\n") }
            .filter { $0.hasPrefix("- pass: ") }
            .map { String($0.dropFirst("- pass: ".count)) })
        return checks.filter { check in
            if passed.contains(where: { $0 == check || $0.hasPrefix(check + " (") }) { return false }
            guard let build, let target = Self.checkin(of: check) else { return true }
            let known = FossilQuery.rows(fossilPath,
                "SELECT 1 FROM blob WHERE uuid LIKE \(FossilQuery.quote(target + "%")) LIMIT 1")
            guard !known.isEmpty else { return true }
            let included = FossilQuery.rows(fossilPath, """
                WITH RECURSIVE anc(rid) AS (
                  SELECT rid FROM blob WHERE uuid LIKE \(FossilQuery.quote(build + "%"))
                  UNION SELECT plink.pid FROM plink JOIN anc ON plink.cid = anc.rid)
                SELECT 1 FROM anc JOIN blob USING(rid)
                WHERE blob.uuid LIKE \(FossilQuery.quote(target + "%")) LIMIT 1
                """)
            return !included.isEmpty
        }
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
        // Hand checks first: a later run reads their passes back from this
        // tag (VerifyList.pending), so the cap must never cut them.
        let text = (hand.map(line) + auto.map(line)).joined(separator: "\n")
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
/// hand check from the "Hand checks" wiki page, then records the run as an `audited` tag on
/// the build's own check-in (in whichever clone has it) and posts a one-line
/// summary to the thread the page names. Both are plain Fossil artifacts
/// written to the clone and pushed by the sync that follows.
struct VerifyView: View {
    @EnvironmentObject private var store: RepoStore
    private let identity = BuildIdentity()
    @State private var list: VerifyList?
    @State private var listSource: String?

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
                    Text(list == nil
                         ? "No clone on this phone has a \"\(VerifyList.page)\" wiki page."
                         : "Nothing to check by hand for this build.")
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
            } footer: {
                if let listSource {
                    Text("From the \"\(VerifyList.page)\" wiki page in \(listSource), as of its last sync. Lines already passed, or for check-ins this build doesn't include, are left out.")
                }
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
                Text("Adds an audited tag (pass, fail, or incomplete when some lines are left unchecked) with every line above to this build's check-in, posts a one-line summary to the thread the wiki page names, and syncs.")
            }
        }
        .navigationTitle("Verify This Build")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadList() }
    }

    @ViewBuilder
    private func mark(_ passed: Bool?) -> some View {
        switch passed {
        case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case false?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case nil: ProgressView()
        }
    }

    // MARK: The hand checks

    /// Reads the wiki page from the clone that has this build's check-in,
    /// else from the first clone that has the page. Fills the hand checks
    /// only when the session has none, so marks already made survive.
    private func loadList() async {
        let tag = FossilQuery.quote("wiki-" + VerifyList.page)
        var source: (Repo, String)?
        if let checkin = identity.fossilCheckin, let (repo, path, _) = await clone(containing: checkin) {
            source = (repo, path)
        }
        if source == nil, let (repo, path, _) = await find("SELECT 'page' FROM tag WHERE tagname = \(tag)") {
            source = (repo, path)
        }
        guard let (repo, path) = source else { return }
        let page = await FossilEngine.shared.run(["wiki", "export", VerifyList.page, "-R", path])
        guard page.succeeded else { return }
        let parsed = VerifyList.parse(page.output)
        let build = identity.fossilCheckin
        let pending = await Task.detached { parsed.pending(build: build, fossilPath: path) }.value
        list = parsed
        listSource = repo.name
        if session.hand.isEmpty {
            session.hand = pending.map { VerifyOutcome(name: $0) }
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

        // The post: a reply to the latest post of the thread the page names.
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
            done.append("Not posted: no clone on this phone has the thread the wiki page names.")
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
