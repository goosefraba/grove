import AppKit
import SwiftUI

final class InspectorViewController: NSViewController {

    private var hostingView: NSHostingView<InspectorView>?
    private var currentItems: [BrowserItem] = []

    override func loadView() {
        let inspectorView = InspectorView(items: [])
        let hosting = NSHostingView(rootView: inspectorView)
        hosting.setFrameSize(NSSize(width: 220, height: 400))
        hostingView = hosting
        view = hosting
    }

    func updateSelection(_ items: [FileItem]) {
        updateSelection(items.map(BrowserItem.local))
    }

    func updateSelection(_ items: [BrowserItem]) {
        currentItems = items
        let inspectorView = InspectorView(items: items)
        hostingView?.rootView = inspectorView
    }
}
