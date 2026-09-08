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

    private func lastClick() -> (x: Double, y: Double)? {
        guard let entry = log.components(separatedBy: " | ").last(where: { $0.hasPrefix("click(1)@") }) else { return nil }
        let parts = entry.replacingOccurrences(of: "click(1)@", with: "").split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// The pointer starts in the middle, and a tap clicks there — wherever the tap is.
    func testTapClicksAtThePointerWhichStartsInTheMiddle() {
        point(0.2, 0.15).tap()
        XCTAssertTrue(waitForLog(containing: "click(1)@"), "a tap should send a left click; log: \(log)")
        guard let click = lastClick() else { return XCTFail("no click in log: \(log)") }
        XCTAssertEqual(click.x, 640, accuracy: 2, "the click should land at the pointer, in the middle; log: \(log)")
        XCTAssertEqual(click.y, 400, accuracy: 2, "log: \(log)")
    }

    /// One finger moves the pointer by its travel: to the right here, then a tap
    /// clicks at the moved pointer, and nothing was dragged or clicked on the way.
    func testOneFingerMovesThePointerRelatively() {
        point(0.3, 0.5).press(forDuration: 0.05, thenDragTo: point(0.7, 0.5))
        XCTAssertTrue(waitForLog(containing: "move"), "the pointer should move live; log: \(log)")
        sleep(1)
        XCTAssertFalse(log.contains("drag@"), "a finger moving must not drag; log: \(log)")
        XCTAssertFalse(log.contains("click"), "a finger moving must not click; log: \(log)")
        point(0.1, 0.9).tap()
        XCTAssertTrue(waitForLog(containing: "click(1)@"), "log: \(log)")
        guard let click = lastClick() else { return XCTFail("no click: \(log)") }
        XCTAssertGreaterThan(click.x, 700, "the pointer should have moved right of the middle; log: \(log)")
        XCTAssertEqual(click.y, 400, accuracy: 6, "and not up or down; log: \(log)")
    }

    /// After a finger lifts, the arrow must stay put: no pointer position may be drawn
    /// after the last move that the finger did not make. Run with pointer logging on.
    func testPointerStaysWhereTheFingerLeftIt() {
        app.terminate()
        app.launchArguments.append("-logPointer")
        app.launch()
        XCTAssertTrue(desktop.waitForExistence(timeout: 60))
        sleep(3)
        point(0.3, 0.5).press(forDuration: 0.05, thenDragTo: point(0.7, 0.6))
        sleep(1)
        let atRelease = log.components(separatedBy: " | ").last(where: { $0.hasPrefix("ptr@") })
        sleep(2)
        let later = log.components(separatedBy: " | ").last(where: { $0.hasPrefix("ptr@") })
        XCTAssertEqual(atRelease, later, "the pointer moved after the finger lifted; log tail: \(log.suffix(400))")
        XCTAssertFalse(log.contains("drag@"), "a plain drag of the finger sent a mouse drag; log: \(log.suffix(300))")
        XCTAssertFalse(log.contains("click"), "a plain drag of the finger clicked; log: \(log.suffix(300))")
    }

    /// A long, slow finger movement — longer than the hold threshold — is still only
    /// the pointer moving, not a hold, a drag or a click.
    func testLongSlowMoveIsOnlyAMove() {
        app.terminate()
        app.launchArguments.append("-logPointer")
        app.launch()
        XCTAssertTrue(desktop.waitForExistence(timeout: 60))
        sleep(3)
        let start = point(0.2, 0.5)
        start.press(forDuration: 0.05, thenDragTo: point(0.4, 0.5))
        point(0.4, 0.5).press(forDuration: 0.05, thenDragTo: point(0.6, 0.55))
        point(0.6, 0.55).press(forDuration: 0.05, thenDragTo: point(0.8, 0.6))
        sleep(2)
        XCTAssertFalse(log.contains("drag@"), "log: \(log.suffix(300))")
        XCTAssertFalse(log.contains("click"), "log: \(log.suffix(300))")
    }

    /// The black margin above the picture is touch too: a drag there moves the pointer.
    func testDragInTheBlackMarginMovesThePointer() {
        point(0.5, 0.08).press(forDuration: 0.05, thenDragTo: point(0.5, 0.2))
        XCTAssertTrue(waitForLog(containing: "move"), "a drag in the margin should move the pointer; log: \(log)")
        point(0.5, 0.08).tap()
        XCTAssertTrue(waitForLog(containing: "click(1)@"), "log: \(log)")
        guard let click = lastClick() else { return XCTFail("no click: \(log)") }
        XCTAssertGreaterThan(click.y, 420, "the pointer should have moved down; log: \(log)")
    }

    /// A finger that pauses past the hold threshold and then keeps moving is still only
    /// pointing: no drag, no right-click. This is the pause a hand makes to aim.
    func testPauseThenMoveOnlyMovesThePointer() {
        point(0.3, 0.6).press(forDuration: 0.7, thenDragTo: point(0.7, 0.6))
        XCTAssertTrue(waitForLog(containing: "move"), "log: \(log)")
        sleep(1)
        XCTAssertFalse(log.contains("drag@"), "a pause then a move must not drag; log: \(log.suffix(300))")
        XCTAssertFalse(log.contains("click"), "a pause then a move must not click; log: \(log.suffix(300))")
    }

    /// Tap, then press and hold, then move: that is the drag, from the pointer.
    func testTapThenHoldThenMoveDrags() {
        let start = point(0.5, 0.5)
        start.tap()
        start.press(forDuration: 0.4, thenDragTo: point(0.7, 0.6))
        XCTAssertTrue(waitForLog(containing: "drag@"), "tap-then-hold-then-move should drag; log: \(log.suffix(300))")
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
