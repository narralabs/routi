import XCTest

/// The phone's desktop, driven with real touches on a simulator against a running core.
///
/// Each test reads back what the app sent the desktop from a log the debug build
/// draws under the picture. That is the whole point: not that a gesture recogniser
/// exists, but that a tap becomes a click, a drag becomes a drag and nothing else,
/// and a hold becomes a right-click. Needs a core on 127.0.0.1:7171 with a bot that
/// has a screen.
final class DesktopTouchTests: XCTestCase {
    private var app: XCUIApplication!
    private var desktop: XCUIElement!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-showScreen", "-daemonHost", "127.0.0.1", "-daemonPort", "7171"]
        app.launch()
        desktop = app.otherElements["desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 60), "the desktop never appeared; is the core running with a bot that has a screen?")
        // The first frame, so the picture has a size and touches map to pixels.
        sleep(3)
    }

    private var log: String { app.staticTexts["inputLog"].label }

    private func waitForLog(containing needle: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if log.contains(needle) { return true }
            usleep(150_000)
        }
        return false
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        desktop.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func testTapClicksWhereTapped() {
        point(0.5, 0.5).tap()
        XCTAssertTrue(waitForLog(containing: "click(1)@"), "a tap should send a left click; log: \(log)")
    }

    func testOneFingerMovesThePointerAndNothingElse() {
        point(0.3, 0.5).press(forDuration: 0.05, thenDragTo: point(0.7, 0.5))
        XCTAssertTrue(waitForLog(containing: "move"), "the pointer should move live; log: \(log)")
        sleep(1)
        XCTAssertFalse(log.contains("drag@"), "a finger moving must not drag; log: \(log)")
        XCTAssertFalse(log.contains("click"), "a finger moving must not click; log: \(log)")
    }

    func testHoldThenMoveDrags() {
        // Rests past the hold threshold, then moves: that is the drag.
        point(0.3, 0.6).press(forDuration: 0.6, thenDragTo: point(0.7, 0.6))
        XCTAssertTrue(waitForLog(containing: "drag@"), "log: \(log)")
        XCTAssertFalse(log.contains("click(3)"), "a hold that moved must not right-click; log: \(log)")
    }

    /// Move to aim, lift, tap near the same place: the click lands where the arrow was
    /// left, not under the finger. A tap elsewhere clicks where it lands. The second
    /// tap is deliberately off by a finger's width, since a hand never returns to the
    /// same pixel.
    func testTapAfterAimingClicksWhereTheArrowIs() {
        point(0.3, 0.5).press(forDuration: 0.05, thenDragTo: point(0.6, 0.5))
        XCTAssertTrue(waitForLog(containing: "move"), "log: \(log)")
        sleep(1)
        let arrowX = 0.6 * 1280.0
        point(0.6 + 12.0 / desktop.frame.width, 0.5 + 8.0 / desktop.frame.height).tap()
        XCTAssertTrue(waitForLog(containing: "click(1)@"), "log: \(log)")
        let click = log.components(separatedBy: " | ").last ?? ""
        let xs = click.replacingOccurrences(of: "click(1)@", with: "").split(separator: ",").first.flatMap { Double($0) } ?? -1
        XCTAssertEqual(xs, arrowX, accuracy: 3, "the tap should click at the arrow's x, not the fingertip's; log: \(log)")
        let arrow = click.replacingOccurrences(of: "click(1)@", with: "")

        point(0.15, 0.2).tap()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, log.components(separatedBy: "click(1)@").count < 3 { usleep(150_000) }
        let last = log.components(separatedBy: " | ").last ?? ""
        XCTAssertTrue(last.hasPrefix("click(1)@") && !last.hasSuffix(arrow), "a tap elsewhere clicks there, not at the arrow; log: \(log)")
    }

    func testHoldRightClicks() {
        point(0.5, 0.5).press(forDuration: 0.9)
        XCTAssertTrue(waitForLog(containing: "click(3)@"), "a hold should right-click; log: \(log)")
    }

    func testTwoFingerTapRightClicks() {
        desktop.twoFingerTap()
        XCTAssertTrue(waitForLog(containing: "click(3)@"), "a two-finger tap should right-click; log: \(log)")
    }

    func testDoubleTapIsTwoQuickClicks() {
        point(0.5, 0.5).doubleTap()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, log.components(separatedBy: "click(1)@").count < 3 { usleep(100_000) }
        XCTAssertEqual(log.components(separatedBy: "click(1)@").count, 3, "two taps, two clicks; log: \(log)")
    }

    func testPinchZoomsWithoutSendingInput() {
        let before = log
        desktop.pinch(withScale: 2.0, velocity: 1.0)
        sleep(1)
        XCTAssertEqual(log, before, "a pinch is the picture's, not the desktop's; log: \(log)")
    }
}
