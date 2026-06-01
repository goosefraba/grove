import Foundation

struct S3BucketSummary: Equatable {
    let name: String
    let creationDate: Date?
}

struct S3ObjectSummary: Equatable {
    let key: String
    let size: Int64
    let lastModified: Date?
    let eTag: String?
    let storageClass: String?
}

struct S3RawListPage: Equatable {
    let commonPrefixes: [String]
    let objects: [S3ObjectSummary]
    let nextContinuationToken: String?
}

struct S3ListPage: Equatable {
    let location: S3Location
    let items: [S3Item]
    let nextContinuationToken: String?
}

final class StaleLoadGuard {
    private var generation: UInt = 0
    private let lock = NSLock()

    func begin() -> UInt {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    func isCurrent(_ value: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }
}

enum S3BrowserError: LocalizedError, Equatable {
    case noProfiles
    case noProfileSelected
    case noBucketSelected
    case missingRegion(profile: String)
    case credentials(String)
    case accessDenied(String)
    case noSuchBucket(String)
    case wrongRegion(expected: String?, actual: String?, message: String)
    case network(String)
    case permission(String)
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .noProfiles:
            return "No AWS profiles were found in ~/.aws/config or ~/.aws/credentials."
        case .noProfileSelected:
            return "Choose an AWS profile before browsing S3."
        case .noBucketSelected:
            return "Enter a bucket name before browsing S3."
        case .missingRegion(let profile):
            return "Profile \(profile) does not define a region. Enter a region to continue."
        case .credentials(let message):
            return "AWS credentials are missing, expired, or invalid. \(message)"
        case .accessDenied(let message):
            return "Access denied. \(message)"
        case .noSuchBucket(let bucket):
            return "Bucket \(bucket) does not exist or is not visible to this profile."
        case .wrongRegion(let expected, let actual, let message):
            let expectedText = expected.map { "Expected \($0)." } ?? ""
            let actualText = actual.map { "Bucket is in \($0)." } ?? ""
            return "Bucket region mismatch. \(expectedText) \(actualText) \(message)"
        case .network(let message):
            return "Network error while contacting S3. \(message)"
        case .permission(let message):
            return "S3 permission error. \(message)"
        case .cancelled:
            return "The S3 request was cancelled."
        case .unknown(let message):
            return message
        }
    }

    var isCredentialProblem: Bool {
        if case .credentials = self { return true }
        return false
    }

    static func classify(_ error: Error, bucket: String? = nil, requestedRegion: String? = nil) -> S3BrowserError {
        if error is CancellationError {
            return .cancelled
        }
        if let browserError = error as? S3BrowserError {
            return browserError
        }

        let nsError = error as NSError
        let raw = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription) \(String(describing: error))"
        let message = sanitized(raw)
        let lower = message.lowercased()

        if lower.contains("expiredtoken") ||
            lower.contains("expired token") ||
            lower.contains("invalidclienttokenid") ||
            lower.contains("unrecognizedclientexception") ||
            lower.contains("invalid security token") ||
            lower.contains("credential") && (lower.contains("missing") || lower.contains("expired") || lower.contains("invalid")) ||
            lower.contains("sso") && lower.contains("expired") {
            return .credentials(message)
        }

        if lower.contains("nosuchbucket") || lower.contains("not found") && bucket != nil {
            return .noSuchBucket(bucket ?? "Unknown")
        }

        if lower.contains("authorizationheadermalformed") ||
            lower.contains("permanentredirect") ||
            lower.contains("wrong region") ||
            lower.contains("x-amz-bucket-region") {
            return .wrongRegion(expected: requestedRegion, actual: regionHint(from: message), message: message)
        }

        if lower.contains("accessdenied") || lower.contains("access denied") {
            return .accessDenied(message)
        }

        if lower.contains("timed out") ||
            lower.contains("cannot connect") ||
            lower.contains("network") ||
            lower.contains("offline") {
            return .network(message)
        }

        if lower.contains("forbidden") || lower.contains("not authorized") {
            return .permission(message)
        }

        return .unknown(message)
    }

    private static func sanitized(_ message: String) -> String {
        var result = message
        let patterns = [
            #"AKIA[0-9A-Z]{16}"#,
            #"ASIA[0-9A-Z]{16}"#,
            #"aws_secret_access_key\s*=\s*[^,\s]+"#,
            #"aws_session_token\s*=\s*[^,\s]+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        if result.count > 600 {
            result = String(result.prefix(600)) + "..."
        }
        return result
    }

    private static func regionHint(from message: String) -> String? {
        let pattern = #"[a-z]{2}-[a-z-]+-\d"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let swiftRange = Range(match.range, in: message) else { return nil }
        return String(message[swiftRange])
    }
}

protocol S3Gateway {
    func listBuckets(profile: AWSProfile, region: String?) async throws -> [S3BucketSummary]
    func bucketRegion(profile: AWSProfile, region: String, bucket: String) async throws -> String?
    func listObjects(location: S3Location, continuationToken: String?, maxKeys: Int) async throws -> S3RawListPage
    func headObject(location: S3Location, key: String) async throws -> S3ObjectMetadata
}

final class S3BrowserService {
    private let gateway: S3Gateway
    private var bucketRegionCache: [String: String] = [:]

    init(gateway: S3Gateway) {
        self.gateway = gateway
    }

    func listBuckets(profile: AWSProfile, regionOverride: String?) async throws -> [S3BucketSummary] {
        try Self.checkCancellation()
        let region = regionOverride ?? profile.regionHint
        do {
            return try await gateway.listBuckets(profile: profile, region: region)
        } catch {
            throw S3BrowserError.classify(error, requestedRegion: region)
        }
    }

    func list(location: S3Location, profile: AWSProfile?, continuationToken: String? = nil, maxKeys: Int = 1_000) async throws -> S3ListPage {
        try Self.checkCancellation()
        guard let profileName = location.effectiveProfileName ?? profile?.name else {
            throw S3BrowserError.noProfileSelected
        }
        guard let bucket = location.bucket, !bucket.isEmpty else {
            throw S3BrowserError.noBucketSelected
        }

        let requestedRegion = location.effectiveRegionOverride ?? profile?.regionHint
        guard let initialRegion = requestedRegion else {
            throw S3BrowserError.missingRegion(profile: profileName)
        }

        let resolvedProfile = profile ?? AWSProfile(
            name: profileName,
            region: requestedRegion,
            sourceProfile: nil,
            ssoSessionName: nil,
            hasStaticCredentials: false,
            hasSessionToken: false,
            hasSSOConfiguration: false
        )

        let region = try await verifiedRegion(
            profile: resolvedProfile,
            requestedRegion: initialRegion,
            bucket: bucket,
            continuationToken: continuationToken
        )
        let verifiedLocation = S3Location(
            profileName: profileName,
            regionOverride: region,
            bucket: bucket,
            prefix: location.prefix
        )

        do {
            try Self.checkCancellation()
            let rawPage = try await gateway.listObjects(location: verifiedLocation, continuationToken: continuationToken, maxKeys: maxKeys)
            try Self.checkCancellation()
            return S3ListPage(
                location: verifiedLocation,
                items: Self.items(from: rawPage, location: verifiedLocation),
                nextContinuationToken: rawPage.nextContinuationToken
            )
        } catch {
            throw S3BrowserError.classify(error, bucket: bucket, requestedRegion: region)
        }
    }

    func loadMetadata(for item: S3Item) async -> S3Item {
        guard !item.isPrefix else { return item }
        do {
            var updated = item
            updated.metadata = try await gateway.headObject(location: item.location, key: item.key)
            return updated
        } catch {
            var updated = item
            updated.metadata = S3ObjectMetadata(
                contentLength: item.size,
                contentType: nil,
                eTag: item.eTag,
                lastModified: item.lastModified,
                storageClass: item.storageClass,
                userMetadata: [:],
                warning: S3BrowserError.classify(error, bucket: item.bucket, requestedRegion: item.location.regionOverride).localizedDescription
            )
            return updated
        }
    }

    private func verifiedRegion(profile: AWSProfile, requestedRegion: String, bucket: String, continuationToken: String?) async throws -> String {
        let cacheKey = "\(profile.name):\(bucket)"
        if let cached = bucketRegionCache[cacheKey] {
            return cached
        }

        guard continuationToken == nil else {
            return requestedRegion
        }

        do {
            if let actual = try await gateway.bucketRegion(profile: profile, region: requestedRegion, bucket: bucket),
               !actual.isEmpty {
                bucketRegionCache[cacheKey] = actual
                return actual
            }
            bucketRegionCache[cacheKey] = requestedRegion
            return requestedRegion
        } catch {
            let classified = S3BrowserError.classify(error, bucket: bucket, requestedRegion: requestedRegion)
            if case .accessDenied = classified {
                return requestedRegion
            }
            throw classified
        }
    }

    private static func checkCancellation() throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw S3BrowserError.cancelled
        }
    }

    static func items(from page: S3RawListPage, location: S3Location) -> [S3Item] {
        guard let bucket = location.bucket else { return [] }

        let prefixItems: [S3Item] = page.commonPrefixes.map { prefix in
            S3Item(
                bucket: bucket,
                key: prefix,
                name: displayName(forKey: prefix, parentPrefix: location.prefix, isPrefix: true),
                isPrefix: true,
                size: nil,
                lastModified: nil,
                eTag: nil,
                storageClass: nil,
                location: location.appendingPrefix(prefix),
                metadata: nil
            )
        }
        let prefixSet = Set(page.commonPrefixes)

        let objectItems: [S3Item] = page.objects.compactMap { object in
            if object.key == location.prefix || object.key.isEmpty {
                return nil
            }
            if object.key.hasSuffix("/"), object.size == 0 {
                guard !prefixSet.contains(object.key) else { return nil }
                return S3Item(
                    bucket: bucket,
                    key: object.key,
                    name: displayName(forKey: object.key, parentPrefix: location.prefix, isPrefix: true),
                    isPrefix: true,
                    size: nil,
                    lastModified: object.lastModified,
                    eTag: object.eTag,
                    storageClass: object.storageClass,
                    location: location.appendingPrefix(object.key),
                    metadata: nil
                )
            }

            return S3Item(
                bucket: bucket,
                key: object.key,
                name: displayName(forKey: object.key, parentPrefix: location.prefix, isPrefix: false),
                isPrefix: false,
                size: object.size,
                lastModified: object.lastModified,
                eTag: object.eTag,
                storageClass: object.storageClass,
                location: location.objectLocation(key: object.key),
                metadata: nil
            )
        }

        return (prefixItems + objectItems).sorted { lhs, rhs in
            if lhs.isPrefix != rhs.isPrefix {
                return lhs.isPrefix
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func displayName(forKey key: String, parentPrefix: String, isPrefix: Bool) -> String {
        var remainder = key
        if !parentPrefix.isEmpty, remainder.hasPrefix(parentPrefix) {
            remainder.removeFirst(parentPrefix.count)
        }
        if isPrefix {
            remainder = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return remainder.split(separator: "/").last.map(String.init) ?? key
    }
}
