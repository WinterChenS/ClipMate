import XCTest
@testable import App

final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(ClipboardContentType.text.rawValue, "text")
    }
}
