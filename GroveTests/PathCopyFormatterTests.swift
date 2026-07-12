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
}
