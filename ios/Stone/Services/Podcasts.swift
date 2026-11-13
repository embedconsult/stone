import Foundation
import AVFoundation
import MediaPlayer

// Podcasts, step 1 of stone-media's BACKLOG.md ("Now first: podcasts";
// maintainer, ocx-console forum fa9d7cbcfe: "can we get some progress on
// stone media store so i can subscribe to podcasts without using apple
// podcasts?"). Paste a feed's address, see its episodes, play one. It
// streams from the publisher; the feed list stays on this phone. Downloads,
// new-episode fetching and stone-media records are later steps.

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
    var errorDescription: String? {
        switch self {
        case .notAFeed: return "That address didn't give a podcast feed (RSS with audio episodes)."
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

/// The subscribed feeds, saved in UserDefaults on this phone.
@MainActor
final class PodcastStore: ObservableObject {
    static let shared = PodcastStore()
    private static let key = "podcastFeeds"

    @Published private(set) var feeds: [PodcastFeed] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            feeds = saved
        }
    }

    /// Fetches the feed, and adds it if it has at least one episode.
    func add(_ url: URL) async throws {
        let (title, episodes) = try await Self.fetch(url)
        guard !episodes.isEmpty else { throw PodcastError.notAFeed }
        if !feeds.contains(where: { $0.url == url }) {
            feeds.append(PodcastFeed(url: url, title: title.isEmpty ? (url.host ?? url.absoluteString) : title))
            save()
        }
    }

    func remove(at offsets: IndexSet) {
        feeds.remove(atOffsets: offsets)
        save()
    }

    static func fetch(_ url: URL) async throws -> (title: String, episodes: [PodcastEpisode]) {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let feed = PodcastFeedParser.parse(data) else { throw PodcastError.notAFeed }
        return feed
    }

    private func save() {
        if let data = try? JSONEncoder().encode(feeds) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
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
