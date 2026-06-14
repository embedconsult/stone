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
            .task { await FossilEngine.shared.setUser(commitAuthor) }
        }
    }
}
