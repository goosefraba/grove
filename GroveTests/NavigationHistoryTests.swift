import XCTest
@testable import Grove

final class NavigationHistoryTests: XCTestCase {
    func testBackForwardNavigation() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let docs = URL(fileURLWithPath: "/tmp/docs")
        let downloads = URL(fileURLWithPath: "/tmp/downloads")
        let history = NavigationHistory(initialURL: home)

        history.navigateTo(docs)
        history.navigateTo(downloads)

        XCTAssertEqual(history.goBack(), docs)
        XCTAssertEqual(history.goBack(), home)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), docs)
    }

    func testBackStackIsCappedAtOneHundredEntries() {
        let history = NavigationHistory(initialURL: URL(fileURLWithPath: "/tmp/0"))

        for index in 1...150 {
            history.navigateTo(URL(fileURLWithPath: "/tmp/\(index)"))
        }

        var backCount = 0
        while history.goBack() != nil {
            backCount += 1
        }

        XCTAssertEqual(backCount, 100)
    }
}
