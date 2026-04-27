import AppKit

enum ViewMode: Int, CaseIterable {
    case list = 0
    case columns = 1
    case icons = 2
    case gallery = 3
}

protocol FileViewControllerProtocol: AnyObject {
    var delegate: FileListViewControllerDelegate? { get set }
    var currentURL: URL { get }
    var showHiddenFiles: Bool { get set }
    var selectedItems: [FileItem] { get }
    var supportsToolbarSearch: Bool { get }
    func loadDirectory(_ url: URL)
    func toggleHiddenFiles()
    func setShowsHiddenFiles(_ visible: Bool)
    func setToolbarFilterText(_ text: String)
    func performToolbarSearch(_ query: String)
    func clearToolbarSearch()
}

extension FileViewControllerProtocol {
    var supportsToolbarSearch: Bool { false }
    func setShowsHiddenFiles(_ visible: Bool) {
        guard showHiddenFiles != visible else { return }
        toggleHiddenFiles()
    }
    func setToolbarFilterText(_ text: String) {}
    func performToolbarSearch(_ query: String) {}
    func clearToolbarSearch() {}
}

enum FileRenameHelper {
    static func defaultSelectionRange(for item: FileItem) -> NSRange {
        let name = item.name as NSString
        guard !(item.isDirectory && !item.isPackage) else {
            return NSRange(location: 0, length: name.length)
        }

        let pathExtension = item.url.pathExtension
        guard !pathExtension.isEmpty else {
            return NSRange(location: 0, length: name.length)
        }

        let suffix = ".\(pathExtension)" as NSString
        guard name.length > suffix.length,
              item.name.hasSuffix(suffix as String) else {
            return NSRange(location: 0, length: name.length)
        }

        return NSRange(location: 0, length: name.length - suffix.length)
    }

    static func presentRenameSheet(
        for item: FileItem,
        from viewController: NSViewController,
        completion: @escaping (URL) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = item.name
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: item.name)
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField

        let rename: () -> Void = {
            let newName = textField.stringValue
            guard !newName.isEmpty, newName != item.name else { return }

            do {
                let newURL = try FileOperationService.shared.rename(item.url, to: newName)
                completion(newURL)
            } catch {
                showError(error, from: viewController)
            }
        }

        if let window = viewController.view.window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                rename()
            }
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(textField)
                selectDefaultTitlePortion(for: item, in: textField, window: alert.window)
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                rename()
            }
        }
    }

    private static func selectDefaultTitlePortion(for item: FileItem, in textField: NSTextField, window: NSWindow) {
        textField.selectText(nil)
        guard let fieldEditor = window.fieldEditor(true, for: textField) else { return }
        fieldEditor.selectedRange = defaultSelectionRange(for: item)
    }

    private static func showError(_ error: Error, from viewController: NSViewController) {
        let alert = NSAlert(error: error)
        if let window = viewController.view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

final class FileConflictResolutionPrompt {
    private weak var window: NSWindow?
    private var applyToAllResolution: FileOperationService.ConflictResolution?

    init(window: NSWindow?) {
        self.window = window
    }

    func resolve(_ conflict: FileOperationService.FileConflict) -> FileOperationService.ConflictResolution {
        if let applyToAllResolution,
           applyToAllResolution != .merge || conflict.canMerge {
            return applyToAllResolution
        }

        let alert = NSAlert()
        alert.messageText = "Conflicting item names"
        alert.informativeText = "An item named \"\(conflict.destinationURL.lastPathComponent)\" already exists in this location."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        if conflict.canMerge {
            alert.addButton(withTitle: "Merge")
        }
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Don't Replace")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all conflicts"

        let response: NSApplication.ModalResponse
        if let window {
            response = alert.runModal()
            window.makeKey()
        } else {
            response = alert.runModal()
        }

        let resolution = resolution(for: response, canMerge: conflict.canMerge)
        if alert.suppressionButton?.state == .on {
            applyToAllResolution = resolution
        }
        return resolution
    }

    private func resolution(
        for response: NSApplication.ModalResponse,
        canMerge: Bool
    ) -> FileOperationService.ConflictResolution {
        switch response {
        case .alertFirstButtonReturn:
            return .replace
        case .alertSecondButtonReturn:
            return canMerge ? .merge : .keepBoth
        case .alertThirdButtonReturn:
            return canMerge ? .keepBoth : .skip
        default:
            return .skip
        }
    }
}
