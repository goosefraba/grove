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

final class PasteboardChangeCoordinatorTests: XCTestCase {
    func testOneChangeInvalidatesEveryLiveWindowObserver() {
        var changeCount = 10
        let coordinator = PasteboardChangeCoordinator(
            changeCountProvider: { changeCount },
            pollingInterval: 60,
            notificationCenter: nil
        )
        var firstWindowInvalidations = 0
        var secondWindowInvalidations = 0
        let firstObservation = coordinator.observe { firstWindowInvalidations += 1 }
        let secondObservation = coordinator.observe { secondWindowInvalidations += 1 }

        changeCount += 1
        coordinator.detectChange()

        XCTAssertEqual(firstWindowInvalidations, 1)
        XCTAssertEqual(secondWindowInvalidations, 1)
        withExtendedLifetime((firstObservation, secondObservation)) {}
    }

    func testObservationDeallocationStopsMonitoringAfterLastWindowCloses() {
        var changeCount = 20
        let coordinator = PasteboardChangeCoordinator(
            changeCountProvider: { changeCount },
            pollingInterval: 60,
            notificationCenter: nil
        )
        var invalidations = 0
        var observation: PasteboardChangeCoordinator.Observation? = coordinator.observe {
            invalidations += 1
        }

        XCTAssertEqual(coordinator.observerCount, 1)
        XCTAssertTrue(coordinator.isMonitoring)

        observation = nil
        XCTAssertNil(observation)
        XCTAssertEqual(coordinator.observerCount, 0)
        XCTAssertFalse(coordinator.isMonitoring)

        changeCount += 1
        coordinator.detectChange()
        XCTAssertEqual(invalidations, 0)
    }
}
