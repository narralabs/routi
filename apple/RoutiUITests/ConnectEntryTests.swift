import XCTest

final class ConnectEntryTests: XCTestCase {
    func testSavedAddressStaysBehindManualConnection() {
        let app = XCUIApplication()
        let savedHost = "old-mac.example.invalid"
        app.launchArguments = ["-daemonHost", savedHost, "-manualCoreConnection", "NO", "-hasCompletedSetup", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["Scan Routi Connect code"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", savedHost)).firstMatch.exists)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        app.buttons["manualCoreConnection"].tap()
        XCTAssertTrue(app.staticTexts["Connect manually"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.firstMatch.value as? String, savedHost)
        app.terminate()
    }
}
