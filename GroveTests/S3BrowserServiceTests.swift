import XCTest
@testable import Grove

final class S3BrowserServiceTests: XCTestCase {
    private let profile = AWSProfile(
        name: "ops",
        region: "us-east-1",
        sourceProfile: nil,
        ssoSessionName: nil,
        hasStaticCredentials: false,
        hasSessionToken: false,
        hasSSOConfiguration: false
    )

    func testListObjectsTransformsPaginationPrefixesObjectsAndFolderMarkers() async throws {
        let gateway = MockS3Gateway()
        gateway.bucketRegionHandler = { _, _, _ in "us-east-1" }
        gateway.listObjectsHandler = { location, token, _ in
            XCTAssertEqual(location.prefix, "logs/")
            XCTAssertNil(token)
            return S3RawListPage(
                commonPrefixes: ["logs/2026/"],
                objects: [
                    S3ObjectSummary(key: "logs/2026/", size: 0, lastModified: nil, eTag: nil, storageClass: nil),
                    S3ObjectSummary(key: "logs/app.log", size: 12, lastModified: Date(timeIntervalSince1970: 10), eTag: "etag", storageClass: "STANDARD"),
                ],
                nextContinuationToken: "next"
            )
        }

        let service = S3BrowserService(gateway: gateway)
        let page = try await service.list(
            location: S3Location(profileName: "ops", regionOverride: nil, bucket: "bucket", prefix: "logs"),
            profile: profile
        )

        XCTAssertEqual(page.nextContinuationToken, "next")
        XCTAssertEqual(page.location.regionOverride, "us-east-1")
        XCTAssertEqual(page.items.map(\.name), ["2026", "app.log"])
        XCTAssertEqual(page.items.map(\.isPrefix), [true, false])
    }

    func testEmptyPrefixReturnsNoItems() async throws {
        let gateway = MockS3Gateway()
        gateway.bucketRegionHandler = { _, _, _ in "us-east-1" }
        gateway.listObjectsHandler = { _, _, _ in S3RawListPage(commonPrefixes: [], objects: [], nextContinuationToken: nil) }

        let page = try await S3BrowserService(gateway: gateway).list(
            location: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: ""),
            profile: profile
        )

        XCTAssertTrue(page.items.isEmpty)
    }

    func testBucketSummariesBecomeNavigableBucketItems() {
        let buckets = [
            S3BucketSummary(name: "zeta", creationDate: nil),
            S3BucketSummary(name: "alpha", creationDate: Date(timeIntervalSince1970: 100)),
        ]

        let items = S3BrowserViewController.bucketItems(from: buckets, profileName: "ops", region: "eu-west-1")

        XCTAssertEqual(items.map(\.name), ["alpha", "zeta"])
        XCTAssertTrue(items.allSatisfy(\.isBucket))
        XCTAssertEqual(items.first?.kind, "S3 Bucket")
        XCTAssertEqual(items.first?.location, S3Location(profileName: "ops", regionOverride: "eu-west-1", bucket: "alpha", prefix: ""))
    }

    func testAccessDeniedAndExpiredCredentialsAreClassified() async {
        XCTAssertTrue(S3BrowserError.classify(MockS3Error("AccessDenied: missing ListBucket")).isAccessDenied)
        XCTAssertTrue(S3BrowserError.classify(MockS3Error("ExpiredToken: token expired")).isCredentialProblem)
    }

    func testWrongRegionVerificationRecreatesListingLocation() async throws {
        let gateway = MockS3Gateway()
        gateway.bucketRegionHandler = { _, region, _ in
            XCTAssertEqual(region, "us-east-1")
            return "eu-central-1"
        }
        gateway.listObjectsHandler = { location, _, _ in
            XCTAssertEqual(location.regionOverride, "eu-central-1")
            return S3RawListPage(commonPrefixes: [], objects: [], nextContinuationToken: nil)
        }

        _ = try await S3BrowserService(gateway: gateway).list(
            location: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: ""),
            profile: profile
        )
    }

    func testCancellationIsReportedAsCancelled() async {
        let gateway = MockS3Gateway()
        gateway.bucketRegionHandler = { _, _, _ in "us-east-1" }
        gateway.listObjectsHandler = { _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return S3RawListPage(commonPrefixes: [], objects: [], nextContinuationToken: nil)
        }
        let task = Task {
            try await S3BrowserService(gateway: gateway).list(
                location: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: ""),
                profile: profile
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as S3BrowserError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHeadObjectMetadataFailureBecomesPartialWarning() async {
        let gateway = MockS3Gateway()
        gateway.headObjectHandler = { _, _ in
            throw MockS3Error("AccessDenied: missing HeadObject")
        }
        let item = S3Item(
            bucket: "bucket",
            key: "file.txt",
            name: "file.txt",
            isPrefix: false,
            size: 10,
            lastModified: nil,
            eTag: "etag",
            storageClass: "STANDARD",
            location: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: "file.txt"),
            metadata: nil
        )

        let updated = await S3BrowserService(gateway: gateway).loadMetadata(for: item)

        XCTAssertEqual(updated.metadata?.contentLength, 10)
        XCTAssertTrue(updated.metadata?.warning?.contains("Access denied") == true)
    }

    func testUploadBuildsPutObjectRequestWithStorageClassContentTypeAndPrefix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("app.txt")
        try Data("hello".utf8).write(to: fileURL)

        let gateway = MockS3Gateway()
        gateway.bucketRegionHandler = { _, _, _ in "us-east-1" }
        gateway.uploadObjectHandler = { request, progress in
            progress?(S3TransferProgress(
                operation: .upload,
                fileName: request.sourceURL.lastPathComponent,
                completedBytes: request.contentLength,
                totalBytes: request.contentLength,
                completedFiles: 1,
                totalFiles: 1
            ))
            return S3UploadResponse(eTag: "etag")
        }

        var progressValues: [S3TransferProgress] = []
        let results = try await S3BrowserService(gateway: gateway).upload(
            localFileURLs: [fileURL],
            to: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: "logs"),
            profile: profile,
            storageClass: .standardIA
        ) { progressValues.append($0) }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(gateway.uploadRequests.count, 1)
        let request = try XCTUnwrap(gateway.uploadRequests.first)
        XCTAssertEqual(request.bucket, "bucket")
        XCTAssertEqual(request.key, "logs/app.txt")
        XCTAssertEqual(request.storageClass, .standardIA)
        XCTAssertEqual(request.contentLength, 5)
        XCTAssertEqual(request.contentType, "text/plain")
        XCTAssertEqual(results.first?.response.eTag, "etag")
        XCTAssertEqual(progressValues.last?.fractionCompleted, 1)
    }

    func testUploadRejectsDirectoriesBeforeGatewayCall() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let gateway = MockS3Gateway()
        do {
            _ = try await S3BrowserService(gateway: gateway).upload(
                localFileURLs: [directory],
                to: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: ""),
                profile: profile,
                storageClass: .standard
            )
            XCTFail("Expected directory upload rejection")
        } catch let error as S3BrowserError {
            XCTAssertTrue(error.localizedDescription.contains("Folder upload is not supported"))
        }
        XCTAssertTrue(gateway.uploadRequests.isEmpty)
    }

    func testDownloadUsesUniqueDestinationForDirectoryConflicts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingURL = directory.appendingPathComponent("app.log")
        try Data("existing".utf8).write(to: existingURL)

        let item = objectItem(name: "app.log", key: "logs/app.log", size: 7)
        let gateway = MockS3Gateway()
        gateway.bucketRegionHandler = { _, _, _ in "us-east-1" }
        gateway.downloadObjectHandler = { request, progress in
            let data = Data("newdata".utf8)
            try data.write(to: request.temporaryURL)
            progress?(S3TransferProgress(
                operation: .download,
                fileName: "app.log",
                completedBytes: Int64(data.count),
                totalBytes: Int64(data.count),
                completedFiles: 1,
                totalFiles: 1
            ))
            return S3DownloadResponse(bytesWritten: Int64(data.count))
        }

        let results = try await S3BrowserService(gateway: gateway).download(
            items: [item],
            to: .directory(directory),
            profile: profile
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.destinationURL.lastPathComponent, "app copy.log")
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(results.first?.destinationURL)), Data("newdata".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(gateway.downloadRequests.first?.temporaryURL.path)))
    }

    func testDownloadFailureCleansTemporaryFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = objectItem(name: "app.log", key: "logs/app.log", size: 7)

        let gateway = MockS3Gateway()
        gateway.bucketRegionHandler = { _, _, _ in "us-east-1" }
        var temporaryURL: URL?
        gateway.downloadObjectHandler = { request, _ in
            temporaryURL = request.temporaryURL
            try Data("partial".utf8).write(to: request.temporaryURL)
            throw MockS3Error("AccessDenied: missing GetObject")
        }

        do {
            _ = try await S3BrowserService(gateway: gateway).download(
                items: [item],
                to: .directory(directory),
                profile: profile
            )
            XCTFail("Expected download failure")
        } catch let error as S3BrowserError {
            XCTAssertTrue(error.isAccessDenied)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(temporaryURL?.path)))
    }

    func testDownloadRejectsPrefixes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = S3Item(
            bucket: "bucket",
            key: "logs/",
            name: "logs",
            isPrefix: true,
            size: nil,
            lastModified: nil,
            eTag: nil,
            storageClass: nil,
            location: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: "logs/"),
            metadata: nil
        )

        do {
            _ = try await S3BrowserService(gateway: MockS3Gateway()).download(
                items: [prefix],
                to: .directory(directory),
                profile: profile
            )
            XCTFail("Expected prefix rejection")
        } catch let error as S3BrowserError {
            XCTAssertTrue(error.localizedDescription.contains("prefixes and buckets cannot be downloaded"))
        }
    }

    func testDragDropUploadValidationRejectsS3RootAndFolders() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("file.txt")
        try Data("ok".utf8).write(to: fileURL)

        XCTAssertNotNil(S3TransferValidator.uploadRejectionReason(
            localFileURLs: [fileURL],
            to: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: nil, prefix: "")
        ))
        XCTAssertNotNil(S3TransferValidator.uploadRejectionReason(
            localFileURLs: [directory],
            to: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: "")
        ))
        XCTAssertNil(S3TransferValidator.uploadRejectionReason(
            localFileURLs: [fileURL],
            to: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: "logs/")
        ))
    }

    func testStaleLoadGuardSuppressesOlderGeneration() {
        let guarder = StaleLoadGuard()
        let first = guarder.begin()
        let second = guarder.begin()

        XCTAssertFalse(guarder.isCurrent(first))
        XCTAssertTrue(guarder.isCurrent(second))
    }
}

private final class MockS3Gateway: S3Gateway {
    var listBucketsHandler: (AWSProfile, String?) async throws -> [S3BucketSummary] = { _, _ in [] }
    var bucketRegionHandler: (AWSProfile, String, String) async throws -> String? = { _, region, _ in region }
    var listObjectsHandler: (S3Location, String?, Int) async throws -> S3RawListPage = { _, _, _ in
        S3RawListPage(commonPrefixes: [], objects: [], nextContinuationToken: nil)
    }
    var headObjectHandler: (S3Location, String) async throws -> S3ObjectMetadata = { _, _ in
        S3ObjectMetadata(contentLength: nil, contentType: nil, eTag: nil, lastModified: nil, storageClass: nil, userMetadata: [:], warning: nil)
    }
    var uploadObjectHandler: (S3UploadRequest, S3TransferProgressHandler?) async throws -> S3UploadResponse = { _, _ in
        S3UploadResponse(eTag: nil)
    }
    var downloadObjectHandler: (S3DownloadRequest, S3TransferProgressHandler?) async throws -> S3DownloadResponse = { _, _ in
        S3DownloadResponse(bytesWritten: 0)
    }

    private(set) var uploadRequests: [S3UploadRequest] = []
    private(set) var downloadRequests: [S3DownloadRequest] = []

    func listBuckets(profile: AWSProfile, region: String?) async throws -> [S3BucketSummary] {
        try await listBucketsHandler(profile, region)
    }

    func bucketRegion(profile: AWSProfile, region: String, bucket: String) async throws -> String? {
        try await bucketRegionHandler(profile, region, bucket)
    }

    func listObjects(location: S3Location, continuationToken: String?, maxKeys: Int) async throws -> S3RawListPage {
        try await listObjectsHandler(location, continuationToken, maxKeys)
    }

    func headObject(location: S3Location, key: String) async throws -> S3ObjectMetadata {
        try await headObjectHandler(location, key)
    }

    func uploadObject(request: S3UploadRequest, progress: S3TransferProgressHandler?) async throws -> S3UploadResponse {
        uploadRequests.append(request)
        return try await uploadObjectHandler(request, progress)
    }

    func downloadObject(request: S3DownloadRequest, progress: S3TransferProgressHandler?) async throws -> S3DownloadResponse {
        downloadRequests.append(request)
        return try await downloadObjectHandler(request, progress)
    }
}

private struct MockS3Error: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private extension S3BrowserError {
    var isAccessDenied: Bool {
        if case .accessDenied = self { return true }
        return false
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GroveS3Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func objectItem(name: String, key: String, size: Int64) -> S3Item {
    S3Item(
        bucket: "bucket",
        key: key,
        name: name,
        isPrefix: false,
        size: size,
        lastModified: nil,
        eTag: nil,
        storageClass: "STANDARD",
        location: S3Location(profileName: "ops", regionOverride: "us-east-1", bucket: "bucket", prefix: key),
        metadata: nil
    )
}
