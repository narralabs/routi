import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The machine the container screens live on, and what to do about it.
///
/// Shared by setup and Settings so the two never disagree about what "ready" means.
/// It asks one question at a time, in the order the fixes go: install Docker, start
/// it, build the desktop. Each state has one primary action, and "check again" for
/// the person who just did the thing in another window.
struct DesktopHostView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("daemonHost") private var host = "127.0.0.1"
    /// Setup wants to know when the machine is ready so it can move on.
    var onReady: (() -> Void)? = nil

    @State private var isPreparing = false
    @State private var failure: String?

    private var isLocal: Bool { host == "127.0.0.1" || host == "localhost" }
    private var status: DesktopHostStatus? { model.desktopHost }

    /// Where the fix happens: here, or on the Mac running the core.
    private var there: String { isLocal ? "this Mac" : "the Mac running Routi Core" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            rows
            if isBuilding { buildProgress }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .task { await model.refreshDesktopHost() }
        // While the machine is being set up the prepare call is away for minutes, so
        // the state is asked for on the side — that is where the step count comes from.
        .task(id: isPreparing) {
            guard isPreparing else { return }
            while isPreparing && !Task.isCancelled {
                await model.refreshDesktopHost()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: status?.isReady ?? false) { _, ready in
            if ready { onReady?() }
        }
    }

    private var isBuilding: Bool { status?.image == .building }

    /**
     What the build is doing, for the minutes it takes.

     A determinate bar when the step count is known, and a plain sentence under it
     rather than the Dockerfile line itself: "Installing the desktop and browser" says
     more to the person waiting than "RUN apt-get install -y --no-install-recommends".
     */
    private var buildProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let build = status?.build, let step = build.step, let of = build.of, of > 0 {
                ProgressView(value: Double(step - 1) / Double(of))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack(spacing: 6) {
                Text(buildCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let elapsed = status?.build?.elapsedMs, elapsed >= 1000 {
                    Text(elapsedText(elapsed))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var buildCaption: String {
        guard let build = status?.build else { return "Starting the build…" }
        let what = describe(instruction: build.detail)
        if let step = build.step, let of = build.of {
            return "Step \(step) of \(of) · \(what)"
        }
        return what
    }

    /// The Dockerfile instruction in a person's words, with a fallback that still reads.
    private func describe(instruction: String) -> String {
        let text = instruction.lowercased()
        if text.isEmpty { return "Preparing…" }
        if text.hasPrefix("from") { return "Downloading Linux" }
        if text.contains("apt-get") { return "Installing the desktop and browser" }
        if text.hasPrefix("useradd") || text.contains("useradd") { return "Setting up the desktop user" }
        if text.hasPrefix("copy") || text.hasPrefix("add") { return "Copying Routi's tools" }
        if text.contains("chmod") { return "Finishing up" }
        return String(instruction.prefix(60))
    }

    private func elapsedText(_ ms: Int) -> String {
        let seconds = ms / 1000
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: - What is true

    @ViewBuilder
    private var rows: some View {
        VStack(spacing: 0) {
            row("Docker", value: dockerLabel, ok: status?.docker == .running, isFirst: true)
            row("Desktop image", value: imageLabel, ok: status?.image == .ready, busy: isBuilding)
            row("Desktop machine", value: machineLabel, ok: status?.machine == .running)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator, lineWidth: 0.5) }
    }

    private func row(_ title: String, value: String, ok: Bool, isFirst: Bool = false, busy: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 12) }
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(status == nil ? Color.secondary : (ok ? Color.green : Color.orange)).frame(width: 7, height: 7)
                    }
                    Text(value).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private var dockerLabel: String {
        guard let status else { return "Checking…" }
        switch status.docker {
        case .missing: return "Not installed"
        case .stopped: return "Not running"
        case .running: return status.dockerVersion.map { "Running · \($0)" } ?? "Running"
        }
    }

    private var imageLabel: String {
        guard let status else { return "Checking…" }
        switch status.image {
        case .unknown: return "—"
        case .missing: return "Not built yet"
        case .building:
            if let step = status.build?.step, let of = status.build?.of { return "Building · step \(step) of \(of)" }
            return "Building…"
        case .ready: return "Ready"
        }
    }

    private var machineLabel: String {
        guard let status else { return "Checking…" }
        switch status.machine {
        case .stopped: return "Stopped"
        case .running: return "Running"
        }
    }

    // MARK: - What to do

    @ViewBuilder
    private var actions: some View {
        if let status {
            HStack(spacing: 10) {
                switch status.docker {
                case .missing:
                    Link("Get Docker Desktop", destination: URL(string: "https://www.docker.com/products/docker-desktop/")!)
                        .buttonStyle(.borderedProminent)
                    Text("Install it on \(there), set it to start at login, then check again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                case .stopped:
                    #if os(macOS)
                    if isLocal {
                        Button("Open Docker Desktop") { openDockerDesktop() }.buttonStyle(.borderedProminent)
                    }
                    #endif
                    Text("Docker Desktop is installed on \(there) but not running. Start it, then check again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .running:
                    if status.isReady {
                        Label("Ready. A bot that asks for a screen gets one.", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5)).foregroundStyle(.green)
                    } else {
                        Button { prepare() } label: {
                            HStack(spacing: 6) {
                                if isPreparing { ProgressView().controlSize(.mini) }
                                Text(isPreparing ? "Setting up…" : (status.image == .ready ? "Start the desktop" : "Set up the desktop"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPreparing || status.image == .building)
                        Text(isPreparing || status.image == .building
                             ? "Downloading Linux and a browser, then building the desktop. A few minutes, once."
                             : status.image == .ready
                                ? "Starts the machine. A few seconds."
                                : "Builds the desktop on \(there). A few minutes, once.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if !status.isReady {
                    Button("Check again") { Task { await model.refreshDesktopHost() } }
                        .controlSize(.small)
                        .disabled(isPreparing)
                }
            }
        }
    }

    private func prepare() {
        failure = nil
        isPreparing = true
        Task {
            do {
                try await model.prepareDesktopHost()
            } catch {
                failure = error.localizedDescription
                await model.refreshDesktopHost()
            }
            isPreparing = false
        }
    }

    #if os(macOS)
    private func openDockerDesktop() {
        let app = URL(fileURLWithPath: "/Applications/Docker.app")
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, _ in
            // Docker takes a while to bring its engine up; keep asking for a bit.
            Task {
                for _ in 0..<20 {
                    try? await Task.sleep(for: .seconds(3))
                    await model.refreshDesktopHost()
                    if model.desktopHost?.docker == .running { break }
                }
            }
        }
    }
    #endif
}
