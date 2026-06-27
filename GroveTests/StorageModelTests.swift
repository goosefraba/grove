import XCTest
@testable import Grove

final class StorageModelTests: XCTestCase {
    func testStorageLocationCodableRoundTripForLocalAndS3() throws {
        let local = StorageLocation.local(URL(fileURLWithPath: "/tmp/grove").standardizedFileURL)
        let s3 = StorageLocation.s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "logs", prefix: "app/2026/"))

        for location in [local, s3] {
            let data = try JSONEncoder().encode(location)
            let decoded = try JSONDecoder().decode(StorageLocation.self, from: data)
            XCTAssertEqual(decoded, location)
        }
    }

    @MainActor
    func testWindowStateMigrationFromCurrentURLUsesRestorePath() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let controller = try XCTUnwrap(BrowserWindowController.restoreState(from: ["currentURL": directory.path]))
        defer { controller.window?.close() }

        XCTAssertEqual(controller.currentLocation, .local(directory.standardizedFileURL))
    }

    func testS3ParentLocationsAndDisplayNames() {
        let root = StorageLocation.s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "logs", prefix: "app/2026/"))

        XCTAssertEqual(root.displayName, "2026")
        XCTAssertEqual(root.parent, .s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "logs", prefix: "app/")))
        XCTAssertEqual(root.parent?.parent, .s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "logs", prefix: "")))
        XCTAssertEqual(root.parent?.parent?.parent, .s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: nil, prefix: "")))
    }

    func testS3ObjectLocationPreservesObjectKeyWithoutFolderSlash() {
        let location = S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: "")
        let objectLocation = location.objectLocation(key: "logs/app.txt")
        let item = S3Item(
            bucket: "bucket",
            key: "logs/app.txt",
            name: "app.txt",
            isPrefix: false,
            size: 12,
            lastModified: nil,
            eTag: nil,
            storageClass: "STANDARD",
            location: objectLocation,
            metadata: nil
        )

        XCTAssertEqual(objectLocation.prefix, "logs/app.txt")
        XCTAssertEqual(BrowserItem.s3(item).storageLocation, .s3(objectLocation))
    }

    func testS3BreadcrumbsUseProfileBucketAndPrefixSemantics() {
        let location = StorageLocation.s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "logs", prefix: "app/2026/"))
        let crumbs = location.breadcrumbs

        XCTAssertEqual(crumbs.map(\.title), ["S3", "ops", "logs", "app", "2026"])
        XCTAssertEqual(crumbs.last?.location, location)
        XCTAssertFalse(crumbs.contains { $0.toolTip.contains("..") })
    }

    func testMixedLocalAndS3NavigationHistory() {
        let home = StorageLocation.local(URL(fileURLWithPath: "/tmp/home"))
        let s3 = StorageLocation.s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "logs", prefix: ""))
        let nested = StorageLocation.s3(S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "logs", prefix: "app/"))
        let history = NavigationHistory(initialLocation: home)

        history.navigateTo(s3)
        history.navigateTo(nested)

        XCTAssertEqual(history.goBackLocation(), s3)
        XCTAssertEqual(history.goBackLocation(), home)
        XCTAssertEqual(history.goForwardLocation(), s3)
    }

    func testMountedVolumeDescriptorUsesMetadataForIdentityAndActions() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Backup"),
            displayName: "Backup",
            volumeName: "Backup",
            uuid: "backup-volume",
            isEjectable: true,
            isRemovable: true,
            isInternal: false,
            isLocal: true,
            isReadOnly: true,
            totalCapacity: 1_000,
            availableCapacity: 400
        )

        XCTAssertEqual(volume.stableIdentifier, "backup-volume")
        XCTAssertEqual(volume.systemImage, "externaldrive")
        XCTAssertEqual(volume.kind, .removable)
        XCTAssertEqual(volume.sidebarDetail, "Removable")
        XCTAssertTrue(volume.supportsEject)
        XCTAssertTrue(volume.toolTip.contains("Removable"))
        XCTAssertTrue(volume.toolTip.contains("Read Only"))
        XCTAssertTrue(volume.toolTip.contains("Ejectable"))
        XCTAssertTrue(volume.contains(URL(fileURLWithPath: "/Volumes/Backup/Photos")))
        XCTAssertFalse(volume.contains(URL(fileURLWithPath: "/Volumes/Backup Clone")))
    }

    func testDiskImageMountedVolumeIsLabeledSeparatelyFromInternalDisk() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Grove Installer"),
            displayName: "Grove Installer",
            uuid: "disk-image-volume",
            isEjectable: true,
            isRemovable: true,
            isInternal: false,
            isLocal: true,
            isReadOnly: true,
            deviceProtocol: "Virtual Interface",
            deviceModel: "Disk Image"
        )

        XCTAssertEqual(volume.kind, .diskImage)
        XCTAssertEqual(volume.systemImage, "opticaldiscdrive")
        XCTAssertEqual(volume.sidebarDetail, "Disk Image")
        XCTAssertTrue(volume.toolTip.contains("Disk Image"))
    }

    func testInternalMountedVolumeDoesNotAdvertiseEject() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/"),
            displayName: "Macintosh HD",
            uuid: "system-volume",
            isEjectable: false,
            isRemovable: false,
            isInternal: true
        )

        XCTAssertEqual(volume.kind, .internalDisk)
        XCTAssertEqual(volume.systemImage, "internaldrive")
        XCTAssertNil(volume.sidebarDetail)
        XCTAssertFalse(volume.supportsEject)
        XCTAssertTrue(volume.contains(URL(fileURLWithPath: "/Users/test/Documents")))
    }

    func testSidebarVolumeItemsDeduplicateSortAndPreserveVolumeMetadata() {
        let backup = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Backup"),
            displayName: "Backup",
            uuid: "same-device",
            isEjectable: true
        )
        let duplicateBackup = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Backup Alias"),
            canonicalURL: URL(fileURLWithPath: "/Volumes/Backup"),
            displayName: "Backup Alias",
            uuid: "same-device",
            isEjectable: true
        )
        let archive = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Archive"),
            displayName: "Archive",
            uuid: "archive-device"
        )

        let items = SidebarItem.volumeItems(from: [backup, duplicateBackup, archive])

        XCTAssertEqual(items.map(\.title), ["Archive", "Backup"])
        XCTAssertEqual(items.map(\.section), [.locations, .locations])
        XCTAssertEqual(items[1].mountedVolume, backup)
        XCTAssertTrue(items[1].representsProvider(of: .local(URL(fileURLWithPath: "/Volumes/Backup/Project"))))
    }

    func testPathCopyFormatterFormatsLocalSidebarFolderPaths() {
        let url = URL(fileURLWithPath: "/tmp/Grove Sidebar/Folder With 'Quote'", isDirectory: true)

        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .unix), "/tmp/Grove Sidebar/Folder With 'Quote'")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .terminal), "'/tmp/Grove Sidebar/Folder With '\\''Quote'\\'''")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .windows), "\\tmp\\Grove Sidebar\\Folder With 'Quote'")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .url), "file:///tmp/Grove%20Sidebar/Folder%20With%20'Quote'/")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .name), "Folder With 'Quote'")
    }

    func testS3CapabilitiesExcludeLocalOnlyCommands() {
        let capabilities = StorageLocation.s3(S3Location()).capabilities

        XCTAssertTrue(capabilities.contains(.browse))
        XCTAssertTrue(capabilities.contains(.s3Upload))
        XCTAssertTrue(capabilities.contains(.s3Download))
        XCTAssertFalse(capabilities.contains(.trash))
        XCTAssertFalse(capabilities.contains(.openTerminal))
        XCTAssertFalse(capabilities.contains(.finderReveal))
        XCTAssertFalse(capabilities.contains(.tags))
        XCTAssertFalse(capabilities.contains(.compression))
        XCTAssertFalse(capabilities.contains(.checksum))
        XCTAssertFalse(capabilities.contains(.rename))
        XCTAssertFalse(capabilities.contains(.localDragDrop))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroveStorageModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
