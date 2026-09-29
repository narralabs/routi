import XCTest

final class ConnectEntryTests: XCTestCase {
    func testSavedAddressStaysBehindManualConnection() {
        let app = XCUIApplication()
        let savedHost = "old-mac.example.invalid"
        app.launchArguments = ["-daemonHost", savedHost, "-manualCoreConnection", "NO", "-hasCompletedSetup", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["Scan pairing code"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", savedHost)).firstMatch.exists)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        app.buttons["manualCoreConnection"].tap()
        XCTAssertTrue(app.staticTexts["Connect manually"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.firstMatch.value as? String, savedHost)
        app.terminate()
    }
    func testUnavailableSavedMacOffersRetryWithoutPairingAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-daemonHost", "127.0.0.1", "-daemonPort", "7199",
                               "-manualCoreConnection", "YES", "-hasCompletedSetup", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Can’t reach 127.0.0.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertFalse(app.buttons["Scan pairing code"].exists)
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["Can’t reach 127.0.0.1"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.terminate()
    }

}
