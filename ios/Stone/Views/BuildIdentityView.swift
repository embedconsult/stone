import SwiftUI

/// Build metadata stamped by `scripts/run-on-device.sh` into the app's
/// Info.plist. Missing values are expected for ordinary Xcode builds.
private struct BuildIdentity {
    let commit: String?
    let date: String?
    let isDirty: Bool

    init(bundle: Bundle = .main) {
        commit = bundle.object(forInfoDictionaryKey: "BuildCommit") as? String
        date = bundle.object(forInfoDictionaryKey: "BuildDate") as? String
        isDirty = (bundle.object(forInfoDictionaryKey: "BuildDirty") as? String) == "true"
    }

    var label: String {
        guard let commit, !commit.isEmpty else { return "Unstamped build" }
        return isDirty ? "\(commit)-dirty" : commit
    }
}

/// A small non-interactive stamp on every screen so a device install can be
/// identified without attaching a debugger.
struct BuildIdentityOverlay: View {
    private let identity = BuildIdentity()

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(identity.label)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
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
        }
        .navigationTitle("About")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
