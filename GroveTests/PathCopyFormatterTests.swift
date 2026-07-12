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
}
