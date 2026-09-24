import SwiftUI

/// Build metadata written into the built app's Info.plist by the "Stamp
/// Build Identity" Xcode build phase (scripts/stamp-build-identity.sh) --
/// a Fossil checkin hash for tethered device builds, a git commit SHA for
/// Xcode Cloud builds. Missing values are expected for ordinary Xcode
/// builds. Not `private` so `BuildIdentity.label` is reachable from
/// StoneTests via `@testable import`.
struct BuildIdentity {
    let commit: String?
    let date: String?
    let isDirty: Bool

    init(bundle: Bundle = .main) {
        commit = bundle.object(forInfoDictionaryKey: "BuildCommit") as? String
        date = bundle.object(forInfoDictionaryKey: "BuildDate") as? String
        isDirty = (bundle.object(forInfoDictionaryKey: "BuildDirty") as? String) == "true"
    }

    var label: String { Self.label(commit: commit, isDirty: isDirty) }

    /// Pure so it's testable without a Bundle/Info.plist fixture -- same
    /// reasoning as RepoStore's sync/credential logic being split into pure
    /// functions for StoneTests.
    static func label(commit: String?, isDirty: Bool) -> String {
        guard let commit, !commit.isEmpty else { return "Unstamped build" }
        return isDirty ? "\(commit)-dirty" : commit
    }
}

/// A small stamp on every screen so a device install can be identified
/// without attaching a debugger. The overlay itself sits in a ZStack over
/// the whole app (see StoneApp), so it stays non-interactive everywhere
/// except the label capsule -- otherwise it would block touches to
/// everything underneath it. That blanket `.allowsHitTesting(false)` also
/// swallowed long-presses on the label itself, so copying the build number
/// silently did nothing (ticket 9626caf291); the capsule re-enables hit
/// testing and text selection for just itself.
struct BuildIdentityOverlay: View {
    private let identity = BuildIdentity()
    @ObservedObject private var visibility = BuildIdentityVisibility.shared

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if !visibility.isHidden {
                    Text(identity.label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.thinMaterial, in: Capsule())
                        .textSelection(.enabled)
                        .allowsHitTesting(true)
                }
            }
        }
        // Pinned to the very bottom of the screen, in the home-indicator
        // strip: below content pinned to the bottom, and behind the keyboard
        // when it is up rather than riding on top of it. As an overlay it
        // cannot move the layout underneath.
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Screens where the build-ID label gets in the way (the conversation view,
/// whose reply box sits where the label does) hide it while they are shown.
@MainActor
final class BuildIdentityVisibility: ObservableObject {
    static let shared = BuildIdentityVisibility()
    @Published private var hiders = 0

    var isHidden: Bool { hiders > 0 }

    func hide() { hiders += 1 }
    func unhide() { hiders = max(0, hiders - 1) }
}

/// Settings destination with the installed app and build identity.
struct AboutView: View {
    private let identity = BuildIdentity()

    var body: some View {
        Form {
            Section("Stone") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: identity.label)
                if let date = identity.date {
                    LabeledContent("Stamped", value: date)
                }
            }
            // Unlike the overlay, this Form has no competing hit-testing
            // override -- the only gap here was never opting in to
            // selection at all.
            .textSelection(.enabled)
        }
        .navigationTitle("About")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
