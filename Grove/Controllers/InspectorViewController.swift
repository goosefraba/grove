import AppKit
import SwiftUI

final class InspectorViewController: NSViewController {

    private var hostingView: NSHostingView<InspectorView>?
    private var currentItem: FileItem?

    override func loadView() {
        let inspectorView = InspectorView(fileItem: nil)
        let hosting = NSHostingView(rootView: inspectorView)
        hosting.setFrameSize(NSSize(width: 220, height: 400))
        hostingView = hosting
        view = hosting
    }

    func updateSelection(_ item: FileItem?) {
        currentItem = item
        let inspectorView = InspectorView(fileItem: item)
        hostingView?.rootView = inspectorView
    }
}
