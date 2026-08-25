import Foundation
import UIKit

/// The closed grammar's terminal vocabulary, from the ticket and the "Stone
/// Remote Operations and Speech Design" wiki page. Feeding this into
/// `SFSpeechRecognizer.contextualStrings` biases recognition toward exactly
/// the utterances gp-crystal's fixed grammar can parse.
enum GpcrGrammar {
    /// Fixed keywords (verbs, prepositions, units) the grammar recognizes.
    static let fixedWords = ["wrap", "block", "with", "repeat", "set", "seconds", "undo"]

    /// The grammar's "numbers" terminal means spoken block indices/durations —
    /// bias on the actual number words, not the literal word "numbers".
    static let numberWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    ]

    static var contextualStrings: [String] { fixedWords + numberWords }
}

/// Client for gp-crystal's capability-gated `/edit` route: a plain HTML form
/// POST of the dictated/typed phrase, as the logged-in user (`RemoteSession`
/// carries the login cookie). Stone does not parse the grammar or render
/// blocks here — that is gp-crystal's job and a later slice, respectively.
/// This proves the loop: phrase -> JSON op -> applied edit.
@MainActor
struct GpcrEditClient {
    struct Result {
        /// The page's own result text: the applied-op JSON, or the
        /// rejection/hint text gp-crystal renders when the phrase doesn't parse.
        let text: String
        /// The full HTML the server returned, for the "view the served page"
        /// visual fallback (rendering blocks natively is a later slice).
        let html: String
    }

    enum ClientError: LocalizedError {
        case emptyPhrase
        case noResult

        var errorDescription: String? {
            switch self {
            case .emptyPhrase: return "Type or dictate a phrase first."
            case .noResult: return "gp-crystal's response had no readable result section."
            }
        }
    }

    let session: RemoteSession

    /// POST `phrase` to the repo-relative `edit` route and pull the result
    /// text back out of the returned page.
    func send(phrase: String) async throws -> Result {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.emptyPhrase }

        let data = try await session.post("edit", form: ["phrase": trimmed])
        guard let html = String(data: data, encoding: .utf8) else {
            throw ClientError.noResult
        }
        guard let text = Self.extractResult(from: html) else {
            throw ClientError.noResult
        }
        return Result(text: text, html: html)
    }

    // MARK: - Result extraction

    /// Best-effort pull of the result text out of gp-crystal's returned page.
    /// Prefers the first `<pre>` block (the conventional place for verbatim
    /// JSON/text output); falls back to the whole document's text content.
    static func extractResult(from html: String) -> String? {
        if let pre = firstPreBlock(in: html), let text = htmlFragmentToText(pre) {
            return text
        }
        return htmlFragmentToText(html)
    }

    private static func firstPreBlock(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<pre[^>]*>(.*?)</pre>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let group = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[group])
    }

    /// Strip tags and decode entities via the system HTML-to-plain-text
    /// converter, so we don't hand-roll an HTML parser for arbitrary markup.
    private static func htmlFragmentToText(_ fragment: String) -> String? {
        guard let data = fragment.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        else { return nil }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
