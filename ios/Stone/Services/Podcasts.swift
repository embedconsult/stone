import Foundation
import AVFoundation
import MediaPlayer

// Podcasts, step 1 of stone-media's BACKLOG.md ("Now first: podcasts";
// maintainer, ocx-console forum fa9d7cbcfe: "can we get some progress on
// stone media store so i can subscribe to podcasts without using apple
// podcasts?"). Paste a feed's address, see its episodes, play one. It
// streams from the publisher. Step 2 keeps the feed list on stone-media's
// wiki page "Podcasts". Downloads and new-episode fetching are later steps.

/// One episode: an RSS item with an audio enclosure.
struct PodcastEpisode: Identifiable, Hashable {
    var id: String { audioURL.absoluteString }
    let title: String
    let date: Date?
    let audioURL: URL
}

/// One subscribed feed, kept on this phone.
struct PodcastFeed: Codable, Identifiable, Hashable {
    var id: String { url.absoluteString }
    let url: URL
    var title: String
}

enum PodcastError: LocalizedError {
    case notAFeed
    case noRepo
    case fossil(String)
    var errorDescription: String? {
        switch self {
        case .notAFeed: return "That address didn't give a podcast feed (RSS with audio episodes)."
        case .noRepo: return "This phone doesn't carry the stone-media repository."
        case .fossil(let output): return output
        }
    }
}

/// Reads an RSS 2.0 feed: the channel's title, and each item's title,
/// pubDate and enclosure url. Items without an enclosure are skipped.
final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private var title = ""
    private var episodes: [PodcastEpisode] = []
    private var inItem = false
    private var text = ""
    private var itemTitle = ""
    private var itemDate: Date?
    private var itemURL: URL?

    /// The channel title and its episodes, newest first; nil if the data
    /// isn't XML.
    static func parse(_ data: Data) -> (title: String, episodes: [PodcastEpisode])? {
        let reader = PodcastFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let sorted = reader.episodes.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return (reader.title, sorted)
    }

    /// RSS dates are RFC 822, e.g. "Wed, 12 Nov 2026 08:00:00 +0000".
    private static let dateFormats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"]
    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "item" {
            inItem = true
            itemTitle = ""
            itemDate = nil
            itemURL = nil
        } else if elementName == "enclosure", inItem, let url = attributeDict["url"].flatMap(URL.init(string:)) {
            itemURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            if inItem { itemTitle = value } else if title.isEmpty { title = value }
        case "pubDate":
            if inItem { itemDate = Self.date(value) }
        case "item":
            inItem = false
            if let url = itemURL {
                episodes.append(PodcastEpisode(title: itemTitle.isEmpty ? url.lastPathComponent : itemTitle,
                                               date: itemDate, audioURL: url))
            }
        default:
            break
        }
        text = ""
    }
}

/// The feed list as stone-media's wiki page "Podcasts" (stone-media
/// BACKLOG.md step 2; maintainer, ocx-console forum 681a172c5d: "i don't
/// know of any repo holding a list."). Markdown, one feed per line,
/// `- [Title](feed address)`, so it reads and edits on the website too.
/// Lines that aren't feeds are kept as they are.
enum PodcastPage {
    static let name = "Podcasts"
    static let header = "Podcast feeds Stone subscribes to, one per line: `- [Title](feed address)`. Edit them here or in Stone.\n\n"

    private static let pattern = #"^\s*[-*]\s*\[(.*)\]\((\S+)\)\s*$"#

    /// The feed a line names, or nil if it isn't a feed line.
    static func feed(_ line: String) -> PodcastFeed? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let titleRange = Range(match.range(at: 1), in: line),
              let urlRange = Range(match.range(at: 2), in: line),
              let url = URL(string: String(line[urlRange])), url.scheme != nil else { return nil }
        return PodcastFeed(url: url, title: String(line[titleRange]))
    }

    static func feeds(_ text: String) -> [PodcastFeed] {
        text.components(separatedBy: "\n").compactMap(feed)
    }

    static func line(_ feed: PodcastFeed) -> String {
        let title = feed.title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "- [\(title)](\(feed.url.absoluteString))"
    }

    /// The page with `added` appended, each feed not already on it.
    static func adding(_ added: [PodcastFeed], to text: String) -> String {
        let have = Set(feeds(text).map(\.url))
        let new = added.filter { !have.contains($0.url) }
        guard !new.isEmpty else { return text }
        var page = text.isEmpty ? header : text
        if !page.hasSuffix("\n") { page += "\n" }
        return page + new.map(line).joined(separator: "\n") + "\n"
    }

    /// The page without the lines naming `url`; every other line as it was.
    static func removing(_ url: URL, from text: String) -> String {
        text.components(separatedBy: "\n").filter { feed($0)?.url != url }.joined(separator: "\n")
    }
}

/// The subscribed feeds, read from and written to the "Podcasts" page of
/// the stone-media repository this phone carries, then synced.
@MainActor
final class PodcastStore: ObservableObject {
    static let shared = PodcastStore()
    /// Where step 1 kept feeds on this phone; merged onto the page once.
    private static let oldKey = "podcastFeeds"
    static let stoneMediaURL = "https://ollama.openbeagle.org/stone-media"

    @Published private(set) var feeds: [PodcastFeed] = []
    /// False when no repository on this phone is stone-media.
    @Published private(set) var hasRepo = true

    /// The repository whose remote ends in /stone-media.
    static func stoneMedia(in repoStore: RepoStore) -> Repo? {
        repoStore.repos.first { repo in
            guard let remote = repo.remoteURL, let url = URL(string: remote) else { return false }
            return url.path.split(separator: "/").last == "stone-media"
        }
    }

    /// Reads the page from this phone's clone; then, if online, syncs and
    /// reads it again, so edits made on the website show.
    func load(_ repoStore: RepoStore) async {
        guard let repo = Self.stoneMedia(in: repoStore) else {
            hasRepo = false
            feeds = []
            return
        }
        hasRepo = true
        let path = repoStore.fileURL(for: repo).path
        await migrate(repo, path: path)
        feeds = PodcastPage.feeds(await Self.readPage(path))
        if (try? await repoStore.sync(repo, trigger: .podcasts)) != nil {
            feeds = PodcastPage.feeds(await Self.readPage(path))
        }
    }

    /// Fetches the feed, and adds it to the page if it has an episode.
    func add(_ url: URL, _ repoStore: RepoStore) async throws {
        guard let repo = Self.stoneMedia(in: repoStore) else { throw PodcastError.noRepo }
        let (title, episodes) = try await Self.fetch(url)
        guard !episodes.isEmpty else { throw PodcastError.notAFeed }
        let feed = PodcastFeed(url: url, title: title.isEmpty ? (url.host ?? url.absoluteString) : title)
        try await edit(repo, repoStore) { PodcastPage.adding([feed], to: $0) }
    }

    func remove(_ feed: PodcastFeed, _ repoStore: RepoStore) async throws {
        guard let repo = Self.stoneMedia(in: repoStore) else { throw PodcastError.noRepo }
        try await edit(repo, repoStore) { PodcastPage.removing(feed.url, from: $0) }
    }

    /// Rewrites the page in this phone's clone, then syncs. Offline, the
    /// edit waits in the clone and goes out with the next sync.
    private func edit(_ repo: Repo, _ repoStore: RepoStore, _ change: (String) -> String) async throws {
        let path = repoStore.fileURL(for: repo).path
        let old = await Self.readPage(path)
        let new = change(old)
        if new != old {
            try await Self.writePage(new, login: ConversationStore.login(for: repo), path: path)
        }
        feeds = PodcastPage.feeds(new)
        _ = try? await repoStore.sync(repo, trigger: .podcasts)
    }

    /// Step 1's feeds, kept in UserDefaults, go onto the page once.
    private func migrate(_ repo: Repo, path: String) async {
        guard let data = UserDefaults.standard.data(forKey: Self.oldKey),
              let old = try? JSONDecoder().decode([PodcastFeed].self, from: data) else { return }
        let page = await Self.readPage(path)
        let merged = PodcastPage.adding(old, to: page)
        if merged != page {
            guard (try? await Self.writePage(merged, login: ConversationStore.login(for: repo), path: path)) != nil else { return }
        }
        UserDefaults.standard.removeObject(forKey: Self.oldKey)
    }

    /// The page's text in the clone; empty if there is no such page.
    static func readPage(_ path: String) async -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("podcasts-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await FossilEngine.shared.run(["wiki", "export", PodcastPage.name, file.path, "-R", path])
        guard result.succeeded else { return "" }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Writes the page with stock commands, as the screenshot code does:
    /// `wiki create` the first time, `wiki commit` after, with -U LOGIN.
    static func writePage(_ text: String, login: String, path: String) async throws {
        let engine = FossilEngine.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("podcasts-\(UUID().uuidString).md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        // -U needs the login in this clone's own user table; adding it is
        // local only (the user table doesn't sync).
        if FossilQuery.rows(path, "SELECT 1 FROM user WHERE login = \(FossilQuery.quote(login))").isEmpty {
            let made = await engine.run(["user", "new", login, "", UUID().uuidString, "-R", path])
            guard made.succeeded else { throw PodcastError.fossil(made.output) }
        }
        let exists = !FossilQuery.rows(path, "SELECT 1 FROM tag WHERE tagname = \(FossilQuery.quote("wiki-" + PodcastPage.name))").isEmpty
        let result = await engine.run(["wiki", exists ? "commit" : "create", PodcastPage.name, file.path,
                                       "--mimetype", "text/x-markdown", "-U", login, "-R", path])
        guard result.succeeded else { throw PodcastError.fossil(result.output) }
    }

    static func fetch(_ url: URL) async throws -> (title: String, episodes: [PodcastEpisode]) {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let feed = PodcastFeedParser.parse(data) else { throw PodcastError.notAFeed }
        return feed
    }
}

/// Plays one episode at a time, streamed from the publisher. The .playback
/// audio session and the audio background mode (Info.plist) keep it
/// playing with the screen locked; the lock screen shows the episode and
/// its play and pause buttons.
@MainActor
final class PodcastPlayer: ObservableObject {
    static let shared = PodcastPlayer()

    @Published private(set) var current: PodcastEpisode?
    @Published private(set) var playing = false
    private var feedTitle = ""
    private let player = AVPlayer()
    private var commandsReady = false

    func play(_ episode: PodcastEpisode, feedTitle: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        player.replaceCurrentItem(with: AVPlayerItem(url: episode.audioURL))
        player.play()
        current = episode
        self.feedTitle = feedTitle
        playing = true
        readyCommands()
        showNowPlaying()
    }

    func toggle() { playing ? pause() : resume() }

    func pause() {
        player.pause()
        playing = false
        showNowPlaying()
    }

    func resume() {
        guard current != nil else { return }
        player.play()
        playing = true
        showNowPlaying()
    }

    private func showNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: feedTitle,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func readyCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
    }
}
