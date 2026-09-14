// Run: swiftc -parse-as-library apple/Routi/State/RoutiUpdate.swift apple/tests/RoutiUpdateTests.swift -o /tmp/routi-update-tests && /tmp/routi-update-tests
import Foundation

@main struct RoutiUpdateTests {
    @MainActor static func main() async {
        let update = RoutiUpdate()
        var steps: [String] = []
        await update.run(prepareApp: { steps.append("prepare"); return "0.1.37" }, updateCore: { version in
            precondition(version == "0.1.37")
            steps.append("core")
        }, installApp: { steps.append("install") })
        precondition(steps == ["prepare", "core", "install"])
        precondition(!update.running)

        steps = []
        await update.run(prepareApp: { "0.1.37" }, updateCore: { _ in
            throw UpdateFailure(message: "Core rolled back")
        }, installApp: { steps.append("install") })
        precondition(steps.isEmpty && update.message == "Core rolled back")

        await update.run(prepareApp: { throw UpdateFailure(message: "Download failed") }, updateCore: { _ in
            steps.append("core")
        }, installApp: { steps.append("install") })
        precondition(steps.isEmpty && update.message == "Download failed")

        await update.run(prepareApp: { nil }, updateCore: { version in
            precondition(version == nil)
            steps.append("core")
        }, installApp: { steps.append("install") })
        precondition(steps == ["core"] && update.message == "Routi is up to date.")

        steps = []
        await update.run(prepareApp: {
            // A second click while preparation is suspended must do nothing.
            await update.run(prepareApp: { steps.append("duplicate"); return nil }, updateCore: { _ in
                steps.append("duplicate")
            }, installApp: { steps.append("duplicate") })
            return "0.1.37"
        }, updateCore: { _ in steps.append("core") }, installApp: { steps.append("install") })
        precondition(steps == ["core", "install"])
        print("5 update coordination checks passed")
    }
}
