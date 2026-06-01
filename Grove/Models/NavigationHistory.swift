import Foundation

final class NavigationHistory {
    private var backStack: [StorageLocation] = []
    private var forwardStack: [StorageLocation] = []
    private(set) var currentLocation: StorageLocation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    init(initialURL: URL) {
        self.currentLocation = .local(initialURL.standardizedFileURL)
    }

    init(initialLocation: StorageLocation) {
        self.currentLocation = initialLocation
    }

    var currentURL: URL {
        currentLocation.localURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func navigateTo(_ url: URL) {
        navigateTo(.local(url.standardizedFileURL))
    }

    func navigateTo(_ location: StorageLocation) {
        backStack.append(currentLocation)
        if backStack.count > 100 {
            backStack.removeFirst()
        }
        currentLocation = location
        forwardStack.removeAll()
    }

    @discardableResult
    func goBackLocation() -> StorageLocation? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(currentLocation)
        currentLocation = previous
        return previous
    }

    @discardableResult
    func goForwardLocation() -> StorageLocation? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(currentLocation)
        currentLocation = next
        return next
    }

    @discardableResult
    func goBack() -> URL? {
        goBackLocation()?.localURL
    }

    @discardableResult
    func goForward() -> URL? {
        goForwardLocation()?.localURL
    }
}
