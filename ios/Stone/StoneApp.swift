import SwiftUI

/// App entry point. Owns the single `RepoStore` and presents the repo list.
@main
struct StoneApp: App {
    @StateObject private var store = RepoStore()
    @AppStorage("commitAuthor") private var commitAuthor = "stone"

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RepoListView()
            }
            .environmentObject(store)
            .task {
                await FossilEngine.shared.setUser(commitAuthor)
                if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem") {
                    await FossilEngine.shared.setCACertificate(path: ca)
                }
                // iOS sets HOME to the read-only sandbox container root, so give
                // Fossil a writable home for its global config DB (~/.fossil).
                if let support = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask).first {
                    try? FileManager.default.createDirectory(
                        at: support, withIntermediateDirectories: true)
                    await FossilEngine.shared.setHome(path: support.path)
                }
            }
        }
    }
}
