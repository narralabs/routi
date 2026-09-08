import XCTest

/// The phone's desktop, driven with real touches on a simulator against a running core.
///
/// Each test reads back what the app sent the desktop from a log the debug build
/// draws under the picture. That is the whole point: not that a gesture recogniser
/// exists, but that a tap becomes a click, a drag becomes a drag and nothing else,
/// and a hold becomes a right-click. Needs a core on 127.0.0.1:7171 with a bot that
/// has a screen.
/// The phone's navigation around the desktop: open a bot, open its screen, close it,
/// go back to the list, and open the same bot again. That last tap did nothing once.
final class PhoneNavigationTests: XCTestCase {
    func testBackFromTheScreenThenTheListThenTheSameBotAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-daemonHost", "127.0.0.1", "-daemonPort", "7171"]
        app.launch()
        let firstBot = app.cells.firstMatch
        XCTAssertTrue(firstBot.waitForExistence(timeout: 30), "no bots listed; is the core running?")
        let name = firstBot.staticTexts.firstMatch.label
        firstBot.tap()
        XCTAssertTrue(app.buttons["showScreen"].waitForExistence(timeout: 10), "the chat should open")
        app.buttons["showScreen"].tap()
        XCTAssertTrue(app.buttons["closeScreen"].waitForExistence(timeout: 10), "the desktop should open")
        app.buttons["closeScreen"].tap()
        XCTAssertTrue(app.buttons["showScreen"].waitForExistence(timeout: 10), "closing the desktop should land on the chat")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10), "back should show the list")
        XCTAssertFalse(app.cells.firstMatch.isSelected, "nothing should stay selected on the list")
        app.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["showScreen"].waitForExistence(timeout: 10), "tapping \(name) again should open its chat")
    }

    /// The initials at the top left open the profile menu, and Settings lives in it.
    /// The menu is where a second profile is switched to; the first profile's name is
    /// what General shows. Needs a core whose first profile is the one showing.
    func testProfileMenuHoldsSwitchAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-daemonHost", "127.0.0.1", "-daemonPort", "7171"]
        app.launch()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30), "no bots listed; is the core running?")
        let menu = app.buttons["profileMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the profile menu should be in the top bar")
        menu.tap()
        XCTAssertTrue(app.buttons["New Profile…"].waitForExistence(timeout: 5), "the menu should offer a new profile")
        XCTAssertTrue(app.buttons["Settings…"].exists, "the menu should offer Settings")
        XCTAssertTrue(app.buttons["Give Feedback…"].exists, "the menu should offer feedback")
        app.buttons["Settings…"].tap()
        // The phone's Settings opens on its list of panes; General is the first.
        let general = app.buttons["General"].exists ? app.buttons["General"] : app.staticTexts["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 10), "Settings should list General")
        general.tap()
        let field = app.textFields["profileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "General should show the profile's name")
        let name = field.value as? String ?? ""
        XCTAssertFalse(name.isEmpty, "the profile should have a name")
        // The profile showing is itself a row of the menu, to switch back to from another.
        // Done lives on the list of panes, one level up from General; the back
        // button carries that list's title.
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "the list of panes should carry Done")
        app.buttons["Done"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5), "the menu should list \(name) among the profiles")
    }
}

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

    /// The keyboard types straight onto the desktop, in order, Return as Return.
    func testKeyboardTypesOntoTheDesktop() {
        app.buttons["keyboard"].tap()
        sleep(1)
        app.typeText("hi\n")
        XCTAssertTrue(waitForLog(containing: "key(Return)"), "Return should reach the desktop; log: \(log.suffix(300))")
        let entries = log.components(separatedBy: " | ")
        let typed = entries.filter { $0.hasPrefix("type(") }.map { $0.dropFirst(5).dropLast() }.joined()
        XCTAssertEqual(typed, "hi", "the letters should reach the desktop; log: \(log.suffix(300))")
        let iType = entries.lastIndex(where: { $0.hasPrefix("type(") }) ?? -1
        let iReturn = entries.lastIndex(of: "key(Return)") ?? -1
        XCTAssertLessThan(iType, iReturn, "the letters must go before Return; log: \(log.suffix(300))")
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
    /// pointing: no drag, no right-click, and the pointer ends where the travel says —
    /// once. It used to end twice as far, since the pan under the hold replayed the
    /// hold's movement on release.
    func testPauseThenMoveOnlyMovesThePointerAndOnlyOnce() {
        app.terminate()
        app.launchArguments.append("-logPointer")
        app.launch()
        XCTAssertTrue(desktop.waitForExistence(timeout: 60))
        sleep(3)
        point(0.3, 0.6).press(forDuration: 0.7, thenDragTo: point(0.7, 0.6))
        sleep(2)
        XCTAssertFalse(log.contains("drag@"), "a pause then a move must not drag; log: \(log.suffix(300))")
        XCTAssertFalse(log.contains("click"), "a pause then a move must not click; log: \(log.suffix(300))")
        guard let last = log.components(separatedBy: " | ").last(where: { $0.hasPrefix("ptr@") }),
              let x = last.replacingOccurrences(of: "ptr@", with: "").split(separator: ",").first.flatMap({ Double($0) })
        else { return XCTFail("no pointer positions logged: \(log.suffix(300))") }
        // 0.4 of the pane's width of finger travel, one to one with the picture, from the
        // middle: 640 + 0.4 × 1280 = 1152. Replayed twice it would be pinned at 1279.
        XCTAssertEqual(x, 1152, accuracy: 60, "the pointer should have moved exactly as far as the finger; log tail: \(log.suffix(200))")
    }

    /// Tap, then press and hold, then move: the button goes down at the pointer when
    /// the hold takes, the pointer moves, and the button comes up where it lifts.
    func testTapThenHoldThenMoveDrags() {
        let start = point(0.5, 0.5)
        start.tap()
        start.press(forDuration: 0.7, thenDragTo: point(0.7, 0.6))
        XCTAssertTrue(waitForLog(containing: "release@"), "tap-then-hold-then-move should end with the button up; log: \(log.suffix(300))")
        let entries = log.components(separatedBy: " | ")
        let iPress = entries.lastIndex(where: { $0.hasPrefix("press@") }) ?? -1
        let iRelease = entries.lastIndex(where: { $0.hasPrefix("release@") }) ?? -1
        XCTAssertGreaterThanOrEqual(iPress, 0, "the button should go down when the hold takes; log: \(log.suffix(300))")
        XCTAssertLessThan(iPress, iRelease, "down before up; log: \(log.suffix(300))")
        XCTAssertTrue(entries[iPress..<iRelease].contains("move"), "the pointer should move between down and up; log: \(log.suffix(300))")
        XCTAssertFalse(log.contains("drag@"), "no atomic drag any more; log: \(log.suffix(300))")
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
