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
