import Foundation

/// An OCX message in a post: a fenced JSON block holding `"ocx"`, the whole
/// post or its end, after words that say it for people (as `ocx2 post`
/// writes a question). Read in either protocol's shape: 1's
/// `{"ocx":1,"kind":KIND,...}` and 2's `{"ocx":2,"to"|"re":...,KIND:{...}}`.
/// Only what Stone shows or answers is read; a key it doesn't know is
/// passed over. Questions and decisions: ollama's
/// docs/protocol-v1-questions.md.
struct OCXMessage: Equatable {
    /// run, started, ended, stop, question, decision.
    let kind: String
    /// 1 or 2: a decision is written in its question's shape.
    let version: Int
    /// For a run, the node it is sent to; for a question, who it asks.
    let to: String?
    /// For a report, the run it answers; for a decision, the question.
    let re: String?
    /// For `started`: the session's login.
    let login: String?
    /// For `ended`: how the run ended.
    let outcome: String?
    /// For a run: what it is for.
    let objective: String?
    /// For a question: what it asks, and its options, the first the one
    /// its asker recommends.
    let question: String?
    let options: [String]
    /// For a decision: the option chosen, or the decider's own words.
    let note: String?
    /// The words before the block, trimmed; empty for a post that is only
    /// the block.
    let prose: String

    init?(_ body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("```"), text.count >= 6 else { return nil }
        let closing = text.index(text.endIndex, offsetBy: -3)
        guard let opening = text.range(of: "```", options: .backwards, range: text.startIndex..<closing),
              opening.lowerBound == text.startIndex || text[text.index(before: opening.lowerBound)] == "\n",
              let lineEnd = text[opening.upperBound..<closing].firstIndex(of: "\n"),
              let data = String(text[lineEnd..<closing]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ocx"] != nil else { return nil }
        prose = text[..<opening.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)

        if let kind = json["kind"] as? String {
            // Protocol 1. An early decision was a `response`.
            self.kind = kind == "response" ? "decision" : kind
            version = 1
            to = (json["node"] as? String) ?? (json["for"] as? String)
            re = (json["run"] as? String) ?? (kind == "question" ? nil : json["question"] as? String)
            login = (json["values"] as? [String: Any])?["user"] as? String
            outcome = json["outcome"] as? String
            objective = json["objective"] as? String
            question = kind == "question" ? json["question"] as? String : nil
            options = json["options"] as? [String] ?? []
            note = json["note"] as? String
            return
        }
        guard let kind = ["run", "started", "ended", "stop", "resume", "question", "decision"]
                .first(where: { json[$0] is [String: Any] }),
              let content = json[kind] as? [String: Any] else { return nil }
        self.kind = kind
        version = 2
        to = json["to"] as? String
        re = json["re"] as? String
        login = (content["values"] as? [String: Any])?["process_user"] as? String
        outcome = content["outcome"] as? String
        objective = content["objective"] as? String
        question = content["question"] as? String
        options = content["options"] as? [String] ?? []
        note = content["note"] as? String
    }

    /// What a bubble shows for the post: its own words when it has them,
    /// else a line for the block. Nil to show the post as written.
    var said: String? {
        if !prose.isEmpty { return prose }
        switch kind {
        case "run": return objective
        case "started": return "*The session started.*"
        case "ended": return outcome.map { "*The session ended: \($0).*" } ?? "*The session ended.*"
        case "stop": return "*Asked the session to stop.*"
        case "resume": return "*Asked the session to resume.*"
        case "decision": return note.map { "**Decision:** \($0)" }
        case "question":
            guard let question else { return nil }
            let asks = to.map { "**Question for \($0):** " } ?? "**Question:** "
            return asks + question
        default: return nil
        }
    }

    /// A decision on this question, the one at `hash`: `note` is an
    /// option's words exactly, or the decider's own. Words for people, then
    /// the message in the question's own protocol.
    func decision(on hash: String, note: String) -> String {
        let message: [String: Any] = version == 1
            ? ["ocx": 1, "kind": "decision", "question": hash, "note": note]
            : ["ocx": 2, "re": hash, "decision": ["note": note]]
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return "**Decision:** \(note)\n\n```json\n\(String(decoding: data, as: UTF8.self))\n```"
    }

    /// The questions in `posts` that have a decision in them, by hash.
    static func decided(in posts: [ConversationPost]) -> Set<String> {
        Set(posts.compactMap { post in
            guard let message = OCXMessage(post.body ?? ""), message.kind == "decision" else { return nil }
            return message.re
        })
    }
}
