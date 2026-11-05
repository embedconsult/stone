import Foundation

/// What the OCX session answering a forum thread is doing, read from the
/// thread's own posts, so it works offline and needs nothing from the
/// server. A session's thread starts with its `run`; OCX's node answers it
/// with `started` and, at the end, `ended` (protocol 2, sections 2.3 and
/// 2.12; protocol 1's `kind` messages too). Between those, the turn is the
/// session's while the latest post is someone else's, and yours once the
/// session has answered.
///
/// Not confirmed by the server's receipts (protocol 2, 2.2): a `started` or
/// `ended` counts when its post's author is the node the run was sent to.
/// That replaced `GET ext/ocx/status`, which went with the old daemon
/// (maintainer, ocx-console forum d77471efb6, Nov 5).
struct AgentStatus: Equatable {
    enum State: Equatable {
        /// The run is sent; its node hasn't started it.
        case waiting
        /// Started, and the latest post isn't the session's: its turn.
        case working
        /// Started, and the session posted last: your turn.
        case yourTurn
        /// The node reported the run over; how, when it said.
        case ended(outcome: String?)
    }

    let state: State
    /// The session's own login (`started`'s `process_user`, or `user` in
    /// protocol 1); nil before it starts.
    let login: String?
    /// When the state began: the run, `started`, the latest post or `ended`.
    let since: Date

    /// The line under the conversation title.
    func label() -> String {
        let who = login ?? "The session"
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: since)
        switch state {
        case .waiting: return "Waiting to start, since \(time)"
        case .working: return "\(who) is working, since \(time)"
        case .yourTurn: return "Your turn, since \(time)"
        case .ended(let outcome): return "Ended at \(time)" + (outcome.map { ": \($0)" } ?? "")
        }
    }

    /// The status of the session `posts` belong to (bodies read), or nil
    /// when the thread doesn't start with a run.
    static func read(_ posts: [ConversationPost]) -> AgentStatus? {
        guard let first = posts.first, let run = OCXMessage(first.body ?? ""), run.kind == "run",
              let node = run.to else { return nil }
        var started: (post: ConversationPost, login: String?)?
        var ended: (post: ConversationPost, outcome: String?)?
        for post in posts.dropFirst() where post.author == node {
            guard let message = OCXMessage(post.body ?? ""), message.re == first.hash else { continue }
            switch message.kind {
            case "started": started = (post, message.login)
            case "ended": ended = (post, message.outcome)
            default: break
            }
        }
        if let ended {
            return AgentStatus(state: .ended(outcome: ended.outcome), login: started?.login, since: ended.post.date)
        }
        guard let started else { return AgentStatus(state: .waiting, login: nil, since: first.date) }
        let latest = posts.last ?? started.post
        if let login = started.login, latest.author.caseInsensitiveCompare(login) == .orderedSame {
            return AgentStatus(state: .yourTurn, login: login, since: latest.date)
        }
        return AgentStatus(state: .working, login: started.login, since: latest.date)
    }
}
