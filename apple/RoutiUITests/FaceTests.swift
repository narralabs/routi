import XCTest

/// The face can be poked on the phone too. The one in the chat's bar is the one to
/// poke: a tap on a face in the bot list opens that bot, which is the list's job.
/// Seven quick taps make it angry, which its accessibility value reports.
final class FaceTests: XCTestCase {
    func testPokingTheHeaderFaceMakesItAngry() {
        let app = XCUIApplication()
        app.launchArguments = ["-daemonHost", "127.0.0.1", "-daemonPort", "7171"]
        app.launch()

        // Open the first bot's chat.
        let firstBot = app.cells.firstMatch
        XCTAssertTrue(firstBot.waitForExistence(timeout: 15), "the bot list should show a bot")
        firstBot.tap()
        XCTAssertTrue(app.buttons["showScreen"].waitForExistence(timeout: 10), "the chat should open")

        let face = app.otherElements["botFace"].firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 5), "the chat's bar should carry the bot's face")
        XCTAssertEqual(face.value as? String, "calm")

        for _ in 0..<7 { face.tap() }

        let angry = expectation(for: NSPredicate(format: "value == 'angry'"), evaluatedWith: face)
        wait(for: [angry], timeout: 3)
    }

    /// On an iPad the bot list stays beside the chat, so its faces can be poked in
    /// place; the tap also selects the row, which is fine — that is the row's job.
    func testPokingAListFaceOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the list leaves the screen on a phone")
        let app = XCUIApplication()
        app.launchArguments = ["-daemonHost", "127.0.0.1", "-daemonPort", "7171"]
        app.launch()

        let firstBot = app.cells.firstMatch
        XCTAssertTrue(firstBot.waitForExistence(timeout: 15), "the bot list should show a bot")
        let face = firstBot.otherElements["botFace"].firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 5), "the row should carry the bot's face")

        for _ in 0..<7 { face.tap() }

        let angry = expectation(for: NSPredicate(format: "value == 'angry'"), evaluatedWith: face)
        wait(for: [angry], timeout: 3)
        XCTAssertTrue(app.buttons["showScreen"].waitForExistence(timeout: 10), "the poked row should also be the selected bot")
    }
}
