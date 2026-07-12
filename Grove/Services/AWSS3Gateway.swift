import Foundation
import CryptoKit

#if canImport(AWSS3) && canImport(AWSSDKIdentity)
import AWSS3
import AWSSDKIdentity
import ClientRuntime
import Smithy

final class AWSS3Gateway: S3Gateway {
    private struct ClientKey: Hashable {
        let profileName: String
        let region: String?
    }

    private struct CachedSSOClient {
        let client: S3Client
        let expiration: Date?
    }

    // Reuse cached credentials/clients until this margin before their expiry, then refresh once.
    private static let credentialRefreshMargin: TimeInterval = 300

    private let profileStore: AWSProfileStore
    private var clients: [ClientKey: S3Client] = [:]
    private var ssoClients: [ClientKey: CachedSSOClient] = [:]
    private lazy var ssoCredentialProvider = NoRefreshSSOCredentialProvider(profileStore: profileStore)
    private let lock = NSLock()

    init(profileStore: AWSProfileStore = AWSProfileStore()) {
        self.profileStore = profileStore
    }

    func listBuckets(profile: AWSProfile, region: String?) async throws -> [S3BucketSummary] {
        let output = try await withClient(profile: profile, region: region) { client in
            try await client.listBuckets(input: ListBucketsInput())
        }
        return (output.buckets ?? []).compactMap { bucket in
            guard let name = bucket.name, !name.isEmpty else { return nil }
            return S3BucketSummary(name: name, creationDate: bucket.creationDate)
        }
    }

    func bucketRegion(profile: AWSProfile, region: String, bucket: String) async throws -> String? {
        let output = try await withClient(profile: profile, region: region) { client in
            try await client.getBucketLocation(input: GetBucketLocationInput(bucket: bucket))
        }
        return normalizedRegion(output.locationConstraint?.rawValue)
    }

    func listObjects(location: S3Location, continuationToken: String?, maxKeys: Int) async throws -> S3RawListPage {
        let profile = profile(named: location.profileName)
        let output = try await withClient(profile: profile, region: location.regionOverride) { client in
            try await client.listObjectsV2(input: ListObjectsV2Input(
                bucket: location.bucket,
                continuationToken: continuationToken,
                delimiter: "/",
                maxKeys: maxKeys,
                prefix: location.prefix.isEmpty ? nil : location.prefix
            ))
        }

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
        let output = try await withClient(profile: profile, region: location.regionOverride) { client in
            try await client.headObject(input: HeadObjectInput(bucket: location.bucket, key: key))
        }
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

    func uploadObject(request: S3UploadRequest, progress: S3TransferProgressHandler?) async throws -> S3UploadResponse {
        try Task.checkCancellation()
        progress?(S3TransferProgress(
            operation: .upload,
            fileName: request.sourceURL.lastPathComponent,
            completedBytes: 0,
            totalBytes: request.contentLength,
            completedFiles: 0,
            totalFiles: 1
        ))

        let fileHandle = try await Task.detached(priority: .userInitiated) {
            try FileHandle(forReadingFrom: request.sourceURL)
        }.value
        defer {
            try? fileHandle.close()
        }
        try Task.checkCancellation()

        let profile = profile(named: request.location.profileName)
        let output = try await withClient(profile: profile, region: request.location.regionOverride) { client in
            try await client.putObject(input: PutObjectInput(
                body: .from(fileHandle: fileHandle),
                bucket: request.bucket,
                contentLength: Int(request.contentLength),
                contentType: request.contentType,
                key: request.key,
                storageClass: request.storageClass.sdkValue
            ))
        }
        try Task.checkCancellation()

        progress?(S3TransferProgress(
            operation: .upload,
            fileName: request.sourceURL.lastPathComponent,
            completedBytes: request.contentLength,
            totalBytes: request.contentLength,
            completedFiles: 1,
            totalFiles: 1
        ))
        return S3UploadResponse(eTag: output.eTag)
    }

    func downloadObject(request: S3DownloadRequest, progress: S3TransferProgressHandler?) async throws -> S3DownloadResponse {
        try Task.checkCancellation()
        let profile = profile(named: request.location.profileName)
        let output = try await withClient(profile: profile, region: request.location.regionOverride) { client in
            try await client.getObject(input: GetObjectInput(bucket: request.bucket, key: request.key))
        }
        try Task.checkCancellation()

        let totalBytes = output.contentLength.map(Int64.init)
        let fileName = (request.key as NSString).lastPathComponent
        progress?(S3TransferProgress(
            operation: .download,
            fileName: fileName,
            completedBytes: 0,
            totalBytes: totalBytes,
            completedFiles: 0,
            totalFiles: 1
        ))
        try Task.checkCancellation()

        let bytesWritten = try await writeBody(
            output.body,
            to: request.temporaryURL,
            fileName: fileName,
            totalBytes: totalBytes,
            progress: progress
        )
        try Task.checkCancellation()

        progress?(S3TransferProgress(
            operation: .download,
            fileName: fileName,
            completedBytes: bytesWritten,
            totalBytes: totalBytes ?? bytesWritten,
            completedFiles: 1,
            totalFiles: 1
        ))
        return S3DownloadResponse(bytesWritten: bytesWritten)
    }

    private func client(profile: AWSProfile, region: String?) async throws -> S3Client {
        if profile.hasSSOConfiguration {
            return try await ssoClient(profile: profile, region: region)
        }

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

    // SSO clients embed a static credential resolved from the SSO portal. Both the client and the
    // underlying credential are cached and reused until the credential nears expiry, so browsing
    // many objects no longer triggers a portal round-trip and a new client per request.
    private func ssoClient(profile: AWSProfile, region: String?) async throws -> S3Client {
        let key = ClientKey(profileName: profile.name, region: region)
        lock.lock()
        let cached = ssoClients[key]
        lock.unlock()
        if let cached, Self.isFresh(cached.expiration) {
            return cached.client
        }

        let identity = try await ssoCredentialProvider.resolve(profileName: profile.name)
        let resolver = try StaticAWSCredentialIdentityResolver(identity)
        let config = try await S3Client.S3ClientConfiguration(
            awsCredentialIdentityResolver: resolver,
            region: region
        )
        let client = S3Client(config: config)

        lock.lock()
        ssoClients[key] = CachedSSOClient(client: client, expiration: identity.expiration)
        lock.unlock()
        return client
    }

    // Runs an S3 operation and, on an authorization failure for an SSO profile, drops the cached
    // credential and client so the next request re-authenticates.
    private func withClient<T>(
        profile: AWSProfile,
        region: String?,
        _ body: (S3Client) async throws -> T
    ) async throws -> T {
        let client = try await client(profile: profile, region: region)
        do {
            return try await body(client)
        } catch {
            if profile.hasSSOConfiguration, Self.isAuthorizationError(error) {
                invalidateSSO(profile: profile, region: region)
            }
            throw error
        }
    }

    private func invalidateSSO(profile: AWSProfile, region: String?) {
        ssoCredentialProvider.invalidate(profileName: profile.name)
        let key = ClientKey(profileName: profile.name, region: region)
        lock.lock()
        ssoClients[key] = nil
        lock.unlock()
    }

    private static func isFresh(_ expiration: Date?) -> Bool {
        guard let expiration else { return false }
        return expiration.timeIntervalSinceNow > credentialRefreshMargin
    }

    private static func isAuthorizationError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let nsError = error as NSError
        let text = "\(nsError.domain) \(nsError.localizedDescription) \(String(describing: error))".lowercased()
        return text.contains("expiredtoken") ||
            text.contains("invalidtoken") ||
            text.contains("accessdenied") ||
            text.contains("access denied") ||
            text.contains("unauthorized") ||
            text.contains("not authorized") ||
            text.contains("forbidden")
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

        throw S3BrowserError.credentials(
            "Profile \(profile.name) is not supported by this read-only S3 slice. Use static credentials or an already-valid SSO profile."
        )
    }

    private func writeBody(
        _ body: ByteStream?,
        to destinationURL: URL,
        fileName: String,
        totalBytes: Int64?,
        progress: S3TransferProgressHandler?
    ) async throws -> Int64 {
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }

        var bytesWritten: Int64 = 0
        switch body {
        case .data(let data):
            if let data, !data.isEmpty {
                try fileHandle.write(contentsOf: data)
                bytesWritten = Int64(data.count)
            }
        case .stream(let stream):
            if stream.isSeekable {
                try stream.seek(toOffset: 0)
            }
            while let chunk = try await stream.readAsync(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try fileHandle.write(contentsOf: chunk)
                bytesWritten += Int64(chunk.count)
                progress?(S3TransferProgress(
                    operation: .download,
                    fileName: fileName,
                    completedBytes: bytesWritten,
                    totalBytes: totalBytes,
                    completedFiles: 0,
                    totalFiles: 1
                ))
            }
        case .noStream, nil:
            break
        }
        return bytesWritten
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

    // GetBucketLocation returns a nil/empty LocationConstraint for us-east-1 and
    // the legacy value "EU" for eu-west-1; every other region is reported verbatim.
    // A nil constraint therefore always maps to us-east-1, regardless of the region
    // the request was issued against, so there is no meaningful caller-supplied fallback.
    private func normalizedRegion(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "us-east-1" }
        if value.lowercased() == "eu" { return "eu-west-1" }
        return value
    }

    private func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == true ? nil : cleaned
    }
}

private extension S3StorageClass {
    var sdkValue: S3ClientTypes.StorageClass {
        switch self {
        case .standard:
            return .standard
        case .intelligentTiering:
            return .intelligentTiering
        case .standardIA:
            return .standardIa
        case .oneZoneIA:
            return .onezoneIa
        case .glacierInstantRetrieval:
            return .glacierIr
        case .glacierFlexibleRetrieval:
            return .glacier
        case .deepArchive:
            return .deepArchive
        case .reducedRedundancy:
            return .reducedRedundancy
        }
    }
}

struct NoRefreshSSOCredentialProvider {
    typealias RoleCredentialLoader = (URLRequest) async throws -> (Data, URLResponse)

    // Reference-type cache so resolved credentials persist across resolve() calls on the same
    // provider instance (the struct is otherwise a value type).
    final class CredentialCache {
        private let lock = NSLock()
        private var entries: [String: AWSCredentialIdentity] = [:]

        func credential(for key: String) -> AWSCredentialIdentity? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ identity: AWSCredentialIdentity, for key: String) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = identity
        }

        func invalidate(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = nil
        }
    }

    let profileStore: AWSProfileStore
    var now: () -> Date = Date.init
    var cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".aws/sso/cache", isDirectory: true)
    var roleCredentialLoader: RoleCredentialLoader = { request in
        try await URLSession.shared.data(for: request)
    }
    // Refresh a cached credential once it is within this margin of its expiry.
    var refreshMargin: TimeInterval = 300
    let credentialCache = CredentialCache()

    func invalidate(profileName: String) {
        credentialCache.invalidate(profileName)
    }

    func resolve(profileName: String) async throws -> AWSCredentialIdentity {
        if let cached = credentialCache.credential(for: profileName),
           let expiration = cached.expiration,
           expiration.timeIntervalSince(now()) > refreshMargin {
            return cached
        }

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

            let identity = AWSCredentialIdentity(
                accessKey: roleCredentials.accessKeyId,
                secret: roleCredentials.secretAccessKey,
                accountID: accountID,
                expiration: roleCredentials.expiration.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                sessionToken: roleCredentials.sessionToken
            )
            credentialCache.store(identity, for: profileName)
            return identity
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

    func uploadObject(request: S3UploadRequest, progress: S3TransferProgressHandler?) async throws -> S3UploadResponse {
        throw S3BrowserError.unknown("AWS SDK for Swift is not linked into this build.")
    }

    func downloadObject(request: S3DownloadRequest, progress: S3TransferProgressHandler?) async throws -> S3DownloadResponse {
        throw S3BrowserError.unknown("AWS SDK for Swift is not linked into this build.")
    }
}
#endif
