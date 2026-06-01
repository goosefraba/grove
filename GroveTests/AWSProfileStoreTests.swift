import Foundation
import XCTest
@testable import Grove

final class AWSProfileStoreTests: XCTestCase {
    func testParsesDefaultProfileProfileSectionsSSOSourceProfileCommentsAndCRLF() {
        let config = """
        # config comment\r
        [default]\r
        region = us-east-1\r
        \r
        [profile ops]\r
        region = eu-west-1 ; inline comment\r
        source_profile = default\r
        \r
        [profile sso]\r
        sso_session = corp\r
        sso_account_id = 123456789012\r
        sso_role_name = Admin\r
        region = us-west-2\r
        \r
        [sso-session corp]\r
        sso_start_url = https://example.awsapps.com/start\r
        sso_region = us-east-1\r
        """.data(using: .utf8)

        let credentials = """
        [default]
        aws_access_key_id = AKIAEXAMPLE
        aws_secret_access_key = secret

        [ops]
        aws_access_key_id = AKIAOPS
        aws_secret_access_key = secret
        aws_session_token = token

        [no-region]
        aws_access_key_id = AKIANOREGION
        aws_secret_access_key = secret
        """.data(using: .utf8)

        let profiles = AWSProfileStore.profiles(configData: config, credentialsData: credentials)

        XCTAssertEqual(profiles.map(\.name), ["default", "no-region", "ops", "sso"])
        XCTAssertEqual(profiles.first { $0.name == "default" }?.region, "us-east-1")
        XCTAssertEqual(profiles.first { $0.name == "ops" }?.region, "eu-west-1")
        XCTAssertEqual(profiles.first { $0.name == "ops" }?.sourceProfile, "default")
        XCTAssertEqual(profiles.first { $0.name == "ops" }?.hasSessionToken, true)
        XCTAssertEqual(profiles.first { $0.name == "sso" }?.hasSSOConfiguration, true)
        XCTAssertEqual(profiles.first { $0.name == "sso" }?.ssoSessionName, "corp")
        XCTAssertNil(profiles.first { $0.name == "no-region" }?.region)
    }

    func testMissingFilesProduceNoProfiles() {
        XCTAssertEqual(AWSProfileStore.profiles(configData: nil, credentialsData: nil), [])
    }

    func testNoRefreshSSOProviderUsesCachedTokenWithoutRefreshing() async throws {
        let files = try makeTemporaryAWSFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        try """
        [profile sso]
        sso_session = corp
        sso_account_id = 123456789012
        sso_role_name = Admin

        [sso-session corp]
        sso_region = us-east-1
        """.write(to: files.config, atomically: true, encoding: .utf8)

        let provider = NoRefreshSSOCredentialProvider(
            profileStore: AWSProfileStore(configURL: files.config, credentialsURL: files.credentials),
            now: { Date(timeIntervalSince1970: 0) },
            cacheDirectory: files.cache,
            roleCredentialLoader: { request in
                XCTAssertEqual(request.url?.host, "portal.sso.us-east-1.amazonaws.com")
                XCTAssertEqual(request.url?.path, "/federation/credentials")
                XCTAssertTrue(request.url?.query?.contains("account_id=123456789012") == true)
                XCTAssertTrue(request.url?.query?.contains("role_name=Admin") == true)
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-sso_bearer_token"), "cached-token")

                let body = """
                {
                  "roleCredentials": {
                    "accessKeyId": "ASIAEXAMPLE",
                    "secretAccessKey": "secret",
                    "sessionToken": "session",
                    "expiration": 4102444800000
                  }
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (body, response)
            }
        )
        try writeCachedSSOToken(cacheDirectory: files.cache, fileName: provider.cachedTokenFileName(for: "corp"), expiresAt: "2099-01-01T00:00:00Z")

        let identity = try await provider.resolve(profileName: "sso")

        XCTAssertEqual(identity.accessKey, "ASIAEXAMPLE")
        XCTAssertEqual(identity.sessionToken, "session")
    }

    func testNoRefreshSSOProviderRejectsExpiredTokenBeforeRoleCredentialRequest() async throws {
        let files = try makeTemporaryAWSFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }

        try """
        [profile sso]
        sso_session = corp
        sso_account_id = 123456789012
        sso_role_name = Admin

        [sso-session corp]
        sso_region = us-east-1
        """.write(to: files.config, atomically: true, encoding: .utf8)

        var didRequestRoleCredentials = false
        let provider = NoRefreshSSOCredentialProvider(
            profileStore: AWSProfileStore(configURL: files.config, credentialsURL: files.credentials),
            now: { Date(timeIntervalSince1970: 100) },
            cacheDirectory: files.cache,
            roleCredentialLoader: { request in
                didRequestRoleCredentials = true
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        )
        try writeCachedSSOToken(cacheDirectory: files.cache, fileName: provider.cachedTokenFileName(for: "corp"), expiresAt: "1970-01-01T00:00:01Z")

        do {
            _ = try await provider.resolve(profileName: "sso")
            XCTFail("Expected expired SSO token to be rejected")
        } catch let error as S3BrowserError {
            guard case .credentials(let message) = error else {
                return XCTFail("Expected credential error, got \(error)")
            }
            XCTAssertTrue(message.contains("expired"))
            XCTAssertFalse(didRequestRoleCredentials)
        }
    }

    private func makeTemporaryAWSFiles() throws -> (root: URL, config: URL, credentials: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = root.appendingPathComponent("sso-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return (
            root,
            root.appendingPathComponent("config"),
            root.appendingPathComponent("credentials"),
            cache
        )
    }

    private func writeCachedSSOToken(cacheDirectory: URL, fileName: String, expiresAt: String) throws {
        let token = """
        {
          "accessToken": "cached-token",
          "expiresAt": "\(expiresAt)"
        }
        """
        try token.write(to: cacheDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }
}
