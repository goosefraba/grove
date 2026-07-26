import XCTest
import AppKit
@testable import Grove

final class BrowserCapabilityTests: XCTestCase {
    @MainActor
    func testSidebarRailRoutesCloudAndTerminalActions() throws {
        let controller = SidebarViewController()
        let delegate = SidebarRailDelegate()
        controller.delegate = delegate
        controller.loadViewIfNeeded()

        let buttons = Self.descendants(of: controller.view).compactMap { $0 as? NSButton }
        let cloudButton = try XCTUnwrap(buttons.first { $0.toolTip == "Amazon S3" })
        let terminalButton = try XCTUnwrap(buttons.first { $0.toolTip == "Open Terminal Here" })

        cloudButton.performClick(nil)
        terminalButton.performClick(nil)

        XCTAssertEqual(delegate.selectedLocation, .s3(S3Location()))
        XCTAssertEqual(delegate.terminalRequestCount, 1)
    }

    func testS3ContextMenuDoesNotAdvertiseLocalOnlyCommands() {
        let location = S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: "")
        let selectedItemSets = [
            [],
            [Self.s3Prefix(location: location)],
            [Self.s3Object(location: location)],
        ]

        for selectedItems in selectedItemSets {
            let titles = Set(S3BrowserViewController.contextMenuItems(for: selectedItems, location: location).map(\.title))
            XCTAssertTrue(titles.isDisjoint(with: S3BrowserViewController.forbiddenLocalCommandTitles))
        }
    }

    func testLocalCapabilitiesStillIncludeExpectedFileOperations() {
        let capabilities = StorageLocation.local(URL(fileURLWithPath: "/tmp")).capabilities

        XCTAssertTrue(capabilities.contains(.createFolder))
        XCTAssertTrue(capabilities.contains(.trash))
        XCTAssertTrue(capabilities.contains(.openTerminal))
        XCTAssertTrue(capabilities.contains(.finderReveal))
        XCTAssertTrue(capabilities.contains(.quickLook))
    }

    func testFileDropOperationPrefersMoveWhenSourceAllowsCopyAndMove() {
        XCTAssertEqual(FileDropOperationResolver.preferredOperation(from: [.copy, .move]), .move)
        XCTAssertEqual(FileDropOperationResolver.preferredOperation(from: [.move]), .move)
        XCTAssertEqual(FileDropOperationResolver.preferredOperation(from: [.copy]), .copy)
    }

    func testTerminalChangeDirectoryScriptShellQuotesPath() {
        let url = URL(fileURLWithPath: "/tmp/Grove $(touch pwn) `echo bad` 'quoted'")
        let script = FileListViewController.terminalChangeDirectoryScript(for: url)

        XCTAssertTrue(script.contains("do script \"cd '"))
        XCTAssertTrue(script.contains("$(touch pwn)"))
        XCTAssertTrue(script.contains("`echo bad`"))
        XCTAssertTrue(script.contains("'\\\\''quoted'\\\\'''"))
        XCTAssertFalse(script.contains("cd \\\"/tmp"))
    }

    func testTerminalTargetUsesSelectedFolderAndFileParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-terminal-target-\(UUID().uuidString)", isDirectory: true)
        let selectedFolder = root.appendingPathComponent("Selected Folder", isDirectory: true)
        let selectedFile = selectedFolder.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: selectedFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let folderItem = try XCTUnwrap(FileItem.load(from: selectedFolder))
        let fileItem = try XCTUnwrap(FileItem.load(from: selectedFile))

        XCTAssertEqual(
            TerminalLauncher.targetDirectory(currentURL: root, selectedItems: [folderItem]),
            selectedFolder.standardizedFileURL
        )
        XCTAssertEqual(
            TerminalLauncher.targetDirectory(currentURL: root, selectedItems: [fileItem]),
            selectedFolder.standardizedFileURL
        )
        XCTAssertEqual(
            TerminalLauncher.targetDirectory(currentURL: root, selectedItems: []),
            root.standardizedFileURL
        )
    }

    func testTerminalCopyPathShellQuotesFileAndFolderPaths() {
        let folderURL = URL(fileURLWithPath: "/tmp/Grove Folder/Sub Folder", isDirectory: true)
        let fileURL = URL(fileURLWithPath: "/tmp/Grove Folder/file 'one' $(touch bad).txt")

        XCTAssertEqual(FileListViewController.terminalCopyPath(for: folderURL), "'/tmp/Grove Folder/Sub Folder'")

        let filePath = FileListViewController.terminalCopyPath(for: fileURL)
        XCTAssertTrue(filePath.hasPrefix("'/tmp/Grove Folder/file "))
        XCTAssertTrue(filePath.contains("'\\''one'\\''"))
        XCTAssertTrue(filePath.contains("$(touch bad)"))
        XCTAssertTrue(filePath.hasSuffix(".txt'"))
    }

    func testS3RegionSuggestionsPreferProfileHintAndResolvedRegionUsesOverride() {
        let suggestions = S3BrowserViewController.regionSuggestions(
            preferredRegion: "eu-central-1",
            knownRegions: ["us-east-1", "eu-central-1", "us-west-2"]
        )

        XCTAssertEqual(suggestions, ["eu-central-1", "us-east-1", "us-west-2"])
        XCTAssertEqual(S3BrowserViewController.resolvedRegion(input: "us-west-2", profileRegion: "eu-central-1"), "us-west-2")
        XCTAssertEqual(S3BrowserViewController.resolvedRegion(input: "", profileRegion: "eu-central-1"), "eu-central-1")
    }

    @MainActor
    func testS3WindowControllerDisablesLocalOnlyMenuActions() {
        let controller = BrowserWindowController(
            initialLocation: .s3(S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: ""))
        )
        defer { controller.window?.close() }

        let newFolder = NSMenuItem(title: "New Folder", action: #selector(BrowserWindowController.createNewFolder(_:)), keyEquivalent: "")
        let showHidden = NSMenuItem(title: "Show Hidden Files", action: #selector(BrowserWindowController.toggleHiddenFiles(_:)), keyEquivalent: "")
        let goToFolder = NSMenuItem(title: "Go to Folder...", action: #selector(BrowserWindowController.goToFolder(_:)), keyEquivalent: "")

        XCTAssertFalse(controller.validateMenuItem(newFolder))
        XCTAssertFalse(controller.validateMenuItem(showHidden))
        XCTAssertFalse(controller.validateMenuItem(goToFolder))
    }

    private static func s3Prefix(location: S3Location) -> S3Item {
        S3Item(
            bucket: "bucket",
            key: "logs/",
            name: "logs",
            isPrefix: true,
            size: nil,
            lastModified: nil,
            eTag: nil,
            storageClass: nil,
            location: location.appendingPrefix("logs/"),
            metadata: nil
        )
    }

    private static func s3Object(location: S3Location) -> S3Item {
        S3Item(
            bucket: "bucket",
            key: "logs/app.txt",
            name: "app.txt",
            isPrefix: false,
            size: 128,
            lastModified: nil,
            eTag: nil,
            storageClass: "STANDARD",
            location: location.objectLocation(key: "logs/app.txt"),
            metadata: nil
        )
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class SidebarRailDelegate: SidebarViewControllerDelegate {
    var selectedLocation: StorageLocation?
    var terminalRequestCount = 0

    func sidebarDidSelect(url: URL) {
        selectedLocation = .local(url.standardizedFileURL)
    }

    func sidebarDidSelect(location: StorageLocation) {
        selectedLocation = location
    }

    func sidebarDidRequestTerminal() {
        terminalRequestCount += 1
    }

    func sidebarDidRequestDualPane() {}
}
