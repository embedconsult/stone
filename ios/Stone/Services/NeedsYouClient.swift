import Foundation

/// Reads the console dashboard's own Needs-you/Try-this lists for a repo
/// (ticket 98c06fb7a7), through an already-authenticated `RemoteSession`.
///
/// This is the fix for the maintainer's "a lot of notifications that don't
/// seem actionable" report: the server already knows which cards the console
/// dashboard shows -- crucially, it already excludes merge cards delegated
/// to the coordinator (`coordinator_queue` below, ticket c974ede9a4) -- so
/// the phone should show exactly that, rather than re-deriving its own rule
/// from a local, possibly-stale clone. `MaintainerRequestStore.scanAfterSync`
/// treats this as the source of truth whenever it's reachable, falling back
/// to `MaintainerRequestScanner`'s local scan only when it isn't.
///
/// Shape and route per the coordinator (ticket 98c06fb7a7 comment,
/// 2026-09-20): "there is no JSON route today; ollama ticket 2f2ab862e3 adds
/// `?console=dashboard&format=json` on the project's console app (same auth
/// as the console page), returning ActivityReport.dashboard unchanged...
/// needs_you, coordinator_queue, try_this arrays with project, hash, title,
/// reason/kind, thread_url ... until it deploys, keep the local scan as the
/// fallback it already is." That ticket hadn't shipped as of this writing,
/// so nothing here has been checked against a real payload -- see the
/// per-field notes below for the specific guesses that will need
/// confirming once it does. Any decode failure (including "404, route
/// doesn't exist yet") is exactly the "unreachable, fall back" case this
/// type's caller already handles.
struct NeedsYouClient {
    enum ClientError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "This server doesn't expose the console dashboard's JSON view, or it can't be reached right now."
        }
    }

    /// One entry in `needs_you` or `try_this`. `reason`/`kind` per the
    /// coordinator's note names either field ambiguously ("reason/kind") --
    /// decoding both, optionally, and treating either one as the place an
    /// `OCX-MERGE-GATE` marker would show up covers that ambiguity without
    /// betting on one exact key surviving to the real deploy.
    ///
    /// No `mtime`/`tkt_mtime` field was mentioned at all. Without one,
    /// `MaintainerRequestStore`'s change-detection key defaults to the empty
    /// string for every server-sourced card (see `fetchCards` below) --
    /// still correct for "don't notify twice for the same still-open card"
    /// (this ticket's actual complaint), just unable to detect "the same
    /// card got edited again" the way a real `tkt_mtime` would. Revisit once
    /// the real shape is confirmed.
    struct Card: Decodable {
        let hash: String
        let title: String
        let reason: String?
        let kind: String?
    }

    private struct Response: Decodable {
        let needsYou: [Card]
        // `coordinator_queue` is intentionally never decoded: those cards
        // are delegated to the coordinator and must never reach the phone
        // (ticket c974ede9a4 / this ticket's "a delegated merge card never
        // notifies").
        let tryThis: [Card]

        enum CodingKeys: String, CodingKey {
            case needsYou = "needs_you"
            case tryThis = "try_this"
        }
    }

    let session: RemoteSession

    /// Fetches the console dashboard's current Needs-you + Try-this cards
    /// for this repo. Throws `.unavailable` for anything short of a
    /// well-formed response -- callers treat that identically to "can't
    /// reach the server at all" and fall back to the local scan, per the
    /// ticket ("keep the local scan only when the server is unreachable").
    func fetchCards() async throws -> [MaintainerRequest] {
        let data = try await session.get("", query: [
            URLQueryItem(name: "console", value: "dashboard"),
            URLQueryItem(name: "format", value: "json"),
        ])
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ClientError.unavailable
        }

        let needsYou = decoded.needsYou.map {
            MaintainerRequest(
                ticketUUID: $0.hash,
                title: $0.title.isEmpty ? "(untitled ticket)" : $0.title,
                mtime: "",
                isMergeGate: Self.isMergeGate($0),
                isDecision: true,
                isTryThis: false)
        }
        let tryThis = decoded.tryThis.map {
            MaintainerRequest(
                ticketUUID: $0.hash,
                title: $0.title.isEmpty ? "(untitled ticket)" : $0.title,
                mtime: "",
                isMergeGate: false,
                isDecision: false,
                isTryThis: true)
        }
        return needsYou + tryThis
    }

    /// Same marker the local scan keys off of
    /// (`MaintainerRequestScanner.scan`'s `comment.contains("OCX-MERGE-GATE")`),
    /// checked against whichever of `reason`/`kind` is actually populated.
    private static func isMergeGate(_ card: Card) -> Bool {
        (card.reason ?? "").contains("OCX-MERGE-GATE") || (card.kind ?? "").contains("OCX-MERGE-GATE")
    }
}
