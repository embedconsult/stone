import SwiftUI

/// Podcasts: paste a feed's address to subscribe; each feed lists its
/// episodes, and a tap plays one (PodcastPlayer). The feeds are stone-media's
/// wiki page "Podcasts" (PodcastStore).
struct PodcastsView: View {
    @EnvironmentObject private var repoStore: RepoStore
    @ObservedObject private var store = PodcastStore.shared
    @State private var addingRepo = false
    @State private var address = ""
    @State private var adding = false
    @State private var error: String?

    private var feedURL: URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    var body: some View {
        Group {
            if store.hasRepo { feedList } else { noRepo }
        }
        .navigationTitle("Podcasts")
        .task(id: repoStore.repos.count) { await store.load(repoStore) }
        .sheet(isPresented: $addingRepo) {
            AddRepoView(name: "stone-media", remoteURL: PodcastStore.stoneMediaURL)
                .environmentObject(repoStore)
        }
    }

    private var noRepo: some View {
        ContentUnavailableView {
            Label("No stone-media here", systemImage: "headphones")
        } description: {
            Text("Your podcast list is the wiki page Podcasts in the stone-media repository, and this phone doesn't carry it.")
        } actions: {
            Button("Add stone-media") { addingRepo = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var feedList: some View {
        List {
            Section {
                HStack {
                    TextField("Feed address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if adding {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await add() } }
                            .disabled(feedURL == nil)
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Paste a podcast's RSS feed address. Feeds are kept on stone-media's wiki page Podcasts; episodes stream from the publisher.")
            }
            if !store.feeds.isEmpty {
                Section("Feeds") {
                    ForEach(store.feeds) { feed in
                        NavigationLink(feed.title) { PodcastEpisodesView(feed: feed) }
                    }
                    .onDelete { offsets in
                        let gone = offsets.map { store.feeds[$0] }
                        Task {
                            for feed in gone {
                                do { try await store.remove(feed, repoStore) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { NowPlayingBar() }
    }

    private func add() async {
        guard let url = feedURL else { return }
        adding = true
        error = nil
        do {
            try await store.add(url, repoStore)
            address = ""
        } catch {
            self.error = error.localizedDescription
        }
        adding = false
    }
}

/// One feed's episodes, newest first, read fresh from the publisher.
struct PodcastEpisodesView: View {
    let feed: PodcastFeed
    @ObservedObject private var player = PodcastPlayer.shared
    @State private var episodes: [PodcastEpisode] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List(episodes) { episode in
            Button {
                player.play(episode, feedTitle: feed.title)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title).foregroundStyle(.primary)
                        if let date = episode.date {
                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if player.current == episode {
                        Image(systemName: player.playing ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .overlay {
            if loading && episodes.isEmpty {
                ProgressView()
            } else if let error, episodes.isEmpty {
                ContentUnavailableView("Couldn't read the feed", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            }
        }
        .navigationTitle(feed.title)
        .task { await load() }
        .refreshable { await load() }
        .safeAreaInset(edge: .bottom) { NowPlayingBar() }
    }

    private func load() async {
        loading = true
        do {
            episodes = try await PodcastStore.fetch(feed.url).episodes
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The playing episode with a play/pause button, shown at the bottom of
/// the podcast screens while one is loaded.
struct NowPlayingBar: View {
    @ObservedObject private var player = PodcastPlayer.shared

    var body: some View {
        if let episode = player.current {
            HStack {
                Text(episode.title).lineLimit(1)
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title2)
                }
                .accessibilityLabel(player.playing ? "Pause" : "Play")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }
}
