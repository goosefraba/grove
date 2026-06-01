import Foundation
import CryptoKit

#if canImport(AWSS3) && canImport(AWSSDKIdentity)
import AWSS3
import AWSSDKIdentity

final class AWSS3Gateway: S3Gateway {
    private struct ClientKey: Hashable {
        let profileName: String
        let region: String?
    }

    private let profileStore: AWSProfileStore
    private var clients: [ClientKey: S3Client] = [:]
    private let lock = NSLock()

    init(profileStore: AWSProfileStore = AWSProfileStore()) {
        self.profileStore = profileStore
    }

    func listBuckets(profile: AWSProfile, region: String?) async throws -> [S3BucketSummary] {
        let client = try await client(profile: profile, region: region)
        let output = try await client.listBuckets(input: ListBucketsInput())
        return (output.buckets ?? []).compactMap { bucket in
            guard let name = bucket.name, !name.isEmpty else { return nil }
            return S3BucketSummary(name: name, creationDate: bucket.creationDate)
        }
    }

    func bucketRegion(profile: AWSProfile, region: String, bucket: String) async throws -> String? {
        let client = try await client(profile: profile, region: region)
        let output = try await client.getBucketLocation(input: GetBucketLocationInput(bucket: bucket))
        return normalizedRegion(output.locationConstraint?.rawValue, fallback: region)
    }

    func listObjects(location: S3Location, continuationToken: String?, maxKeys: Int) async throws -> S3RawListPage {
        let profile = profile(named: location.profileName)
        let client = try await client(profile: profile, region: location.regionOverride)
        let output = try await client.listObjectsV2(input: ListObjectsV2Input(
            bucket: location.bucket,
            continuationToken: continuationToken,
            delimiter: "/",
            maxKeys: maxKeys,
            prefix: location.prefix.isEmpty ? nil : location.prefix
        ))

        return S3RawListPage(
            commonPrefixes: (output.commonPrefixes ?? []).compactMap(\.prefix),
            objects: (output.contents ?? []).compactMap { object in
                guard let key = object.key else { return nil }
                return S3ObjectSummary(
                    key: key,
                    size: Int64(object.size ?? 0),
                    lastModified: object.lastModified,
                    eTag: object.eTag,
                    storageClass: object.storageClass.map { String(describing: $0) }
                )
            },
            nextContinuationToken: output.nextContinuationToken
        )
    }

    func headObject(location: S3Location, key: String) async throws -> S3ObjectMetadata {
        let profile = profile(named: location.profileName)
        let client = try await client(profile: profile, region: location.regionOverride)
        let output = try await client.headObject(input: HeadObjectInput(bucket: location.bucket, key: key))
        return S3ObjectMetadata(
            contentLength: output.contentLength.map(Int64.init),
            contentType: output.contentType,
            eTag: output.eTag,
            lastModified: output.lastModified,
            storageClass: output.storageClass.map { String(describing: $0) },
            userMetadata: output.metadata ?? [:],
            warning: nil
        )
    }

    private func client(profile: AWSProfile, region: String?) async throws -> S3Client {
        let key = ClientKey(profileName: profile.name, region: region)
        lock.lock()
        let existing = clients[key]
        lock.unlock()
        if let existing {
            return existing
        }

        let created = try await makeClient(profile: profile, region: region)
        lock.lock()
        clients[key] = created
        lock.unlock()
        return created
    }

    private func makeClient(profile: AWSProfile, region: String?) async throws -> S3Client {
        if let staticCredentials = staticCredentialIdentity(for: profile.name) {
            let resolver = try StaticAWSCredentialIdentityResolver(staticCredentials)
            let config = try await S3Client.S3ClientConfiguration(
                awsCredentialIdentityResolver: resolver,
                region: region
            )
            return S3Client(config: config)
        }

        if profile.hasSSOConfiguration {
            let identity = try await NoRefreshSSOCredentialProvider(profileStore: profileStore)
                .resolve(profileName: profile.name)
            let resolver = try StaticAWSCredentialIdentityResolver(identity)
            let config = try await S3Client.S3ClientConfiguration(
                awsCredentialIdentityResolver: resolver,
                region: region
            )
            return S3Client(config: config)
        }

        throw S3BrowserError.credentials(
            "Profile \(profile.name) is not supported by this read-only S3 slice. Use static credentials or an already-valid SSO profile."
        )
    }

    private func profile(named name: String?) -> AWSProfile {
        let profileName = name ?? "default"
        return profileStore.profiles().first { $0.name == profileName } ?? AWSProfile(
            name: profileName,
            region: nil,
            sourceProfile: nil,
            ssoSessionName: nil,
            hasStaticCredentials: false,
            hasSessionToken: false,
            hasSSOConfiguration: false
        )
    }

    private func staticCredentialIdentity(for profileName: String) -> AWSCredentialIdentity? {
        let sections = AWSINIParser.parse(data: try? Data(contentsOf: profileStore.credentialsURL))
        guard let values = sections[profileName],
              let accessKey = clean(values["aws_access_key_id"]),
              let secret = clean(values["aws_secret_access_key"]) else {
            return nil
        }
        return AWSCredentialIdentity(
            accessKey: accessKey,
            secret: secret,
            sessionToken: clean(values["aws_session_token"])
        )
    }

    private func normalizedRegion(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return "us-east-1" }
        if value.lowercased() == "eu" { return "eu-west-1" }
        return value
    }

    private func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == true ? nil : cleaned
    }
}

struct NoRefreshSSOCredentialProvider {
    typealias RoleCredentialLoader = (URLRequest) async throws -> (Data, URLResponse)

    let profileStore: AWSProfileStore
    var now: () -> Date = Date.init
    var cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".aws/sso/cache", isDirectory: true)
    var roleCredentialLoader: RoleCredentialLoader = { request in
        try await URLSession.shared.data(for: request)
    }

    func resolve(profileName: String) async throws -> AWSCredentialIdentity {
        let config = AWSINIParser.parse(data: try? Data(contentsOf: profileStore.configURL))
        let profileSection = profileName == "default" ? "default" : "profile \(profileName)"
        guard let profileValues = config[profileSection] else {
            throw S3BrowserError.credentials("Profile \(profileName) was not found in ~/.aws/config.")
        }

        guard let accountID = clean(profileValues["sso_account_id"]),
              let roleName = clean(profileValues["sso_role_name"]) else {
            throw S3BrowserError.credentials("Profile \(profileName) is missing SSO account or role configuration.")
        }

        let sessionName = clean(profileValues["sso_session"])
        let region = try ssoRegion(profileValues: profileValues, sessionName: sessionName, config: config, profileName: profileName)
        let cacheKey = try tokenCacheKey(profileValues: profileValues, sessionName: sessionName, profileName: profileName)
        let token = try loadCachedToken(cacheKey: cacheKey)

        guard token.expiresAt > now() else {
            throw S3BrowserError.credentials("The cached SSO token for profile \(profileName) is expired. Refresh the AWS profile outside Grove and retry.")
        }

        let request = try getRoleCredentialsRequest(region: region, accountID: accountID, roleName: roleName, accessToken: token.accessToken)
        let (data, response) = try await roleCredentialLoader(request)
        try validate(response: response, profileName: profileName)

        do {
            let output = try JSONDecoder().decode(SSORoleCredentialsOutput.self, from: data)
            guard let roleCredentials = output.roleCredentials,
                  !roleCredentials.accessKeyId.isEmpty,
                  !roleCredentials.secretAccessKey.isEmpty else {
                throw S3BrowserError.credentials("SSO did not return usable role credentials for profile \(profileName).")
            }

            return AWSCredentialIdentity(
                accessKey: roleCredentials.accessKeyId,
                secret: roleCredentials.secretAccessKey,
                accountID: accountID,
                expiration: roleCredentials.expiration.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                sessionToken: roleCredentials.sessionToken
            )
        } catch let error as S3BrowserError {
            throw error
        } catch {
            throw S3BrowserError.credentials("SSO returned an unreadable role credential response for profile \(profileName).")
        }
    }

    func cachedTokenFileName(for cacheKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(cacheKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func ssoRegion(
        profileValues: [String: String],
        sessionName: String?,
        config: [String: [String: String]],
        profileName: String
    ) throws -> String {
        if let sessionName,
           let sessionRegion = clean(config["sso-session \(sessionName)"]?["sso_region"]) {
            return sessionRegion
        }
        if let legacyRegion = clean(profileValues["sso_region"]) {
            return legacyRegion
        }
        throw S3BrowserError.credentials("Profile \(profileName) is missing SSO region configuration.")
    }

    private func tokenCacheKey(profileValues: [String: String], sessionName: String?, profileName: String) throws -> String {
        if let sessionName {
            return sessionName
        }
        if let startURL = clean(profileValues["sso_start_url"]) {
            return startURL
        }
        throw S3BrowserError.credentials("Profile \(profileName) is missing SSO session or start URL configuration.")
    }

    private func loadCachedToken(cacheKey: String) throws -> CachedSSOToken {
        let tokenURL = cacheDirectory.appendingPathComponent(cachedTokenFileName(for: cacheKey))
        do {
            return try JSONDecoder().decode(CachedSSOToken.self, from: Data(contentsOf: tokenURL))
        } catch {
            throw S3BrowserError.credentials("The cached SSO token is missing or unreadable.")
        }
    }

    private func getRoleCredentialsRequest(region: String, accountID: String, roleName: String, accessToken: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "portal.sso.\(region).amazonaws.com"
        components.path = "/federation/credentials"
        components.queryItems = [
            URLQueryItem(name: "account_id", value: accountID),
            URLQueryItem(name: "role_name", value: roleName),
        ]

        guard let url = components.url else {
            throw S3BrowserError.credentials("Could not create an SSO role credential request.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        return request
    }

    private func validate(response: URLResponse, profileName: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401:
            throw S3BrowserError.credentials("The cached SSO token for profile \(profileName) was rejected.")
        case 403:
            throw S3BrowserError.accessDenied("SSO denied role credentials for profile \(profileName).")
        default:
            throw S3BrowserError.network("SSO role credential request failed with HTTP \(httpResponse.statusCode).")
        }
    }

    private func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == true ? nil : cleaned
    }
}

struct CachedSSOToken: Decodable {
    let accessToken: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken
        case expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        let expiresAtText = try container.decode(String.self, forKey: .expiresAt)
        guard let parsed = Self.parseDate(expiresAtText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: container,
                debugDescription: "Invalid SSO token expiration"
            )
        }
        expiresAt = parsed
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct SSORoleCredentialsOutput: Decodable {
    let roleCredentials: SSORoleCredentials?
}

private struct SSORoleCredentials: Decodable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let expiration: Int64?
}
#else
final class AWSS3Gateway: S3Gateway {
    func listBuckets(profile: AWSProfile, region: String?) async throws -> [S3BucketSummary] {
        throw S3BrowserError.unknown("AWS SDK for Swift is not linked into this build.")
    }

    func bucketRegion(profile: AWSProfile, region: String, bucket: String) async throws -> String? {
        throw S3BrowserError.unknown("AWS SDK for Swift is not linked into this build.")
    }

    func listObjects(location: S3Location, continuationToken: String?, maxKeys: Int) async throws -> S3RawListPage {
        throw S3BrowserError.unknown("AWS SDK for Swift is not linked into this build.")
    }

    func headObject(location: S3Location, key: String) async throws -> S3ObjectMetadata {
        throw S3BrowserError.unknown("AWS SDK for Swift is not linked into this build.")
    }
}
#endif
