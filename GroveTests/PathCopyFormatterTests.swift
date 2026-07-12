import XCTest
@testable import Grove

final class PathCopyFormatterTests: XCTestCase {
    // MARK: - HFS paths (#16)

    func testHFSPathBootVolumePrependsVolumeName() {
        let result = PathCopyFormatter.hfsPath(
            pathComponents: ["/", "Users", "x", "file"],
            bootVolumeName: "Macintosh HD"
        )
        XCTAssertEqual(result, "Macintosh HD:Users:x:file")
    }

    func testHFSPathNonBootVolumeStripsVolumesPrefix() {
        let result = PathCopyFormatter.hfsPath(
            pathComponents: ["/", "Volumes", "USB", "Documents", "file.txt"],
            bootVolumeName: "Macintosh HD"
        )
        XCTAssertEqual(result, "USB:Documents:file.txt")
    }

    func testHFSPathNonBootVolumeRootIsJustVolumeName() {
        let result = PathCopyFormatter.hfsPath(
            pathComponents: ["/", "Volumes", "USB"],
            bootVolumeName: "Macintosh HD"
        )
        XCTAssertEqual(result, "USB")
    }

    func testHFSPathBootVolumeVolumesDirectoryIsNotTreatedAsMount() {
        // `/Volumes` on the boot volume has only one trailing component and must
        // not be mistaken for a non-boot volume prefix.
        let result = PathCopyFormatter.hfsPath(
            pathComponents: ["/", "Volumes"],
            bootVolumeName: "Macintosh HD"
        )
        XCTAssertEqual(result, "Macintosh HD:Volumes")
    }

    // MARK: - Windows / UNC paths (#28)

    func testWindowsUNCPathFromSMBMount() {
        let result = PathCopyFormatter.windowsUNCPath(
            mountFromName: "//user@server/share",
            mountPoint: "/Volumes/share",
            filePath: "/Volumes/share/dir/file.txt"
        )
        XCTAssertEqual(result, #"\\server\share\dir\file.txt"#)
    }

    func testWindowsUNCPathFromSMBMountAtShareRoot() {
        let result = PathCopyFormatter.windowsUNCPath(
            mountFromName: "//server/share",
            mountPoint: "/Volumes/share",
            filePath: "/Volumes/share"
        )
        XCTAssertEqual(result, #"\\server\share"#)
    }

    func testWindowsUNCPathWithSMBSchemePrefix() {
        let result = PathCopyFormatter.windowsUNCPath(
            mountFromName: "smb://server/share",
            mountPoint: "/Volumes/share",
            filePath: "/Volumes/share/file"
        )
        XCTAssertEqual(result, #"\\server\share\file"#)
    }

    func testWindowsUNCPathReturnsNilForLocalMount() {
        let result = PathCopyFormatter.windowsUNCPath(
            mountFromName: "/dev/disk1s1",
            mountPoint: "/",
            filePath: "/Users/x/file"
        )
        XCTAssertNil(result)
    }

    func testWindowsFormatFallsBackToBackslashForLocalPath() {
        // A real local path (home directory) is not an SMB mount, so the copied
        // value is the documented backslash-separated fallback.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let result = PathCopyFormatter.string(for: home, format: .windows)
        XCTAssertEqual(result, home.path.replacingOccurrences(of: "/", with: "\\"))
        XCTAssertFalse(result.contains("/"))
    }

    // MARK: - Boot-volume paths, all six format modes

    func testUnixReturnsRawPOSIXPath() {
        let url = URL(fileURLWithPath: "/Users/me/Documents/report.txt")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .unix), "/Users/me/Documents/report.txt")
    }

    func testWindowsReplacesSeparatorsWithBackslashes() {
        let url = URL(fileURLWithPath: "/Users/me/Documents/report.txt")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .windows), "\\Users\\me\\Documents\\report.txt")
    }

    func testTerminalSingleQuotesAndEscapesEmbeddedQuotes() {
        let url = URL(fileURLWithPath: "/Users/me/my file's.txt")
        // Single-quote the path and render embedded ' as '\'' so it is copy-paste-ready in a shell.
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .terminal), "'/Users/me/my file'\\''s.txt'")
    }

    func testURLReturnsFileScheme() {
        let url = URL(fileURLWithPath: "/Users/me/report.txt")
        let formatted = PathCopyFormatter.string(for: url, format: .url)
        XCTAssertEqual(formatted, url.absoluteString)
        XCTAssertTrue(formatted.hasPrefix("file://"))
    }

    func testNameReturnsLastComponent() {
        let url = URL(fileURLWithPath: "/Users/me/Documents/report.txt")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .name), "report.txt")
    }

    func testHFSUsesVolumeNamePrefixAndColonSeparatorsOnBootVolume() throws {
        let dir = FileManager.default.temporaryDirectory
        let volumeName = try XCTUnwrap((try dir.resourceValues(forKeys: [.volumeNameKey])).volumeName)
        let hfs = PathCopyFormatter.string(for: dir, format: .hfs)

        XCTAssertFalse(hfs.contains("/"), "HFS path must not contain POSIX separators: \(hfs)")
        XCTAssertTrue(hfs.hasPrefix(volumeName + ":"), "expected \(hfs) to start with \(volumeName):")
    }

    // MARK: - External /Volumes paths

    func testExternalVolumeUnixWindowsAndName() {
        let url = URL(fileURLWithPath: "/Volumes/External Drive/Projects/build.sh")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .unix), "/Volumes/External Drive/Projects/build.sh")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .windows), "\\Volumes\\External Drive\\Projects\\build.sh")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .name), "build.sh")
    }

    func testExternalVolumeTerminalQuotesSpaces() {
        let url = URL(fileURLWithPath: "/Volumes/External Drive/Projects/build.sh")
        XCTAssertEqual(PathCopyFormatter.string(for: url, format: .terminal), "'/Volumes/External Drive/Projects/build.sh'")
    }

    func testExternalVolumeHFSJoinsComponentsWithColon() {
        // Volume-name lookup fails for a non-mounted /Volumes path, so components are colon-joined
        // with no volume prefix — and never contain POSIX separators.
        let url = URL(fileURLWithPath: "/Volumes/Ghost/dir/file.txt")
        let hfs = PathCopyFormatter.string(for: url, format: .hfs)
        XCTAssertFalse(hfs.contains("/"))
        XCTAssertTrue(hfs.contains(":"))
        XCTAssertTrue(hfs.hasSuffix("file.txt"))
    }
}
