import SwiftUI

struct BuildIdentityOverlay: View {
    @State private var opacity = 0.0

    var body: some View {
        Text(buildId)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(8)
            .background(Color.black.opacity(0.6))
            .cornerRadius(8)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 1.0)) { opacity = 1.0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.easeOut(duration: 1.0)) { opacity = 0.0 }
                }
            }
    }

    private var buildId: String {
        let commit = Bundle.main.infoDictionary?["BuildCommit"] as? String ?? "unknown"
        let date = Bundle.main.infoDictionary?["BuildDate"] as? String ?? "unknown"
        return "Build: \(commit) (\(date))"
    }
}