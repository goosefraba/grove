import Foundation

final class NavigationHistory {
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private(set) var currentURL: URL

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    init(initialURL: URL) {
        self.currentURL = initialURL
    }

    func navigateTo(_ url: URL) {
        backStack.append(currentURL)
        if backStack.count > 100 {
            backStack.removeFirst()
        }
        currentURL = url
        forwardStack.removeAll()
    }

    @discardableResult
    func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(currentURL)
        currentURL = previous
        return previous
    }

    @discardableResult
    func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(currentURL)
        currentURL = next
        return next
    }
}
