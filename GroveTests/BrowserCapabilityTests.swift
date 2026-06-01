import XCTest
import AppKit
@testable import Grove

final class BrowserCapabilityTests: XCTestCase {
    func testS3ContextMenuDoesNotAdvertiseLocalOnlyCommands() {
        let allowedTitles: Set<String> = ["Open Bucket", "Open Prefix", "Copy S3 URI"]
        XCTAssertTrue(allowedTitles.isDisjoint(with: S3BrowserViewController.forbiddenLocalCommandTitles))
    }

    func testLocalCapabilitiesStillIncludeExpectedFileOperations() {
        let capabilities = StorageLocation.local(URL(fileURLWithPath: "/tmp")).capabilities

        XCTAssertTrue(capabilities.contains(.createFolder))
        XCTAssertTrue(capabilities.contains(.trash))
        XCTAssertTrue(capabilities.contains(.openTerminal))
        XCTAssertTrue(capabilities.contains(.finderReveal))
        XCTAssertTrue(capabilities.contains(.quickLook))
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
}
