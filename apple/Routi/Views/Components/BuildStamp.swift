import SwiftUI

#if DEBUG
/// Which build is actually on screen.
///
/// Debug only. Reading it off the window beats inferring it from file timestamps,
/// which is what we were reduced to whenever a change did not seem to have landed.
struct BuildStamp: View {
    private var stamp: String {
        let info = Bundle.main.infoDictionary
        let time = info?["RoutiBuildTime"] as? String ?? "?"
        let commit = info?["RoutiBuildCommit"] as? String ?? "?"
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build)) · \(time) · \(commit)"
    }

    var body: some View {
        Text(stamp)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .textSelection(.enabled)
            .help("Debug build stamp")
            .accessibilityIdentifier("buildStamp")
    }
}
#endif
