import Foundation
import UniformTypeIdentifiers

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

enum S3StorageClass: String, CaseIterable, Equatable {
    case standard = "STANDARD"
    case intelligentTiering = "INTELLIGENT_TIERING"
    case standardIA = "STANDARD_IA"
    case oneZoneIA = "ONEZONE_IA"
    case glacierInstantRetrieval = "GLACIER_IR"
    case glacierFlexibleRetrieval = "GLACIER"
    case deepArchive = "DEEP_ARCHIVE"
    case reducedRedundancy = "REDUCED_REDUNDANCY"

    var displayName: String {
        switch self {
        case .standard:
            return "STANDARD"
        case .intelligentTiering:
            return "INTELLIGENT_TIERING"
        case .standardIA:
            return "STANDARD_IA"
        case .oneZoneIA:
            return "ONEZONE_IA"
        case .glacierInstantRetrieval:
            return "GLACIER_IR"
        case .glacierFlexibleRetrieval:
            return "GLACIER"
        case .deepArchive:
            return "DEEP_ARCHIVE"
        case .reducedRedundancy:
            return "REDUCED_REDUNDANCY"
        }
    }
}

struct S3UploadRequest: Equatable {
    let location: S3Location
    let sourceURL: URL
    let bucket: String
    let key: String
    let storageClass: S3StorageClass
    let contentType: String?
    let contentLength: Int64
}

struct S3UploadResponse: Equatable {
    let eTag: String?
}

enum S3DownloadDestination: Equatable {
    case file(URL)
    case directory(URL)
}

struct S3DownloadRequest: Equatable {
    let location: S3Location
    let bucket: String
    let key: String
    let temporaryURL: URL
}

struct S3DownloadResponse: Equatable {
    let bytesWritten: Int64
}

struct S3UploadResult: Equatable {
    let request: S3UploadRequest
    let response: S3UploadResponse
}

struct S3DownloadResult: Equatable {
    let item: S3Item
    let destinationURL: URL
    let bytesWritten: Int64
}

enum S3TransferOperation: Equatable {
    case upload
    case download
}

struct S3TransferProgress: Equatable {
    let operation: S3TransferOperation
    let fileName: String
    let completedBytes: Int64
    let totalBytes: Int64?
    let completedFiles: Int
    let totalFiles: Int

    var fractionCompleted: Double? {
        guard totalFiles > 0 else { return nil }
        let filePortion = 1.0 / Double(totalFiles)
        let completedFilePortion = Double(completedFiles) * filePortion
        guard let totalBytes, totalBytes > 0 else {
            return min(1, completedFilePortion)
        }
        let currentFilePortion = min(1, max(0, Double(completedBytes) / Double(totalBytes))) * filePortion
        return min(1, completedFilePortion + currentFilePortion)
    }
}

typealias S3TransferProgressHandler = (S3TransferProgress) -> Void

enum S3TransferValidator {
    static func canUpload(to location: S3Location) -> Bool {
        location.bucket?.isEmpty == false
    }

    static func canDownload(_ items: [S3Item]) -> Bool {
        !items.isEmpty && items.allSatisfy { !$0.isPrefix }
    }

    static func uploadRejectionReason(localFileURLs urls: [URL], to location: S3Location, fileManager: FileManager = .default) -> String? {
        guard canUpload(to: location) else {
            return "Open a concrete S3 bucket or prefix before uploading."
        }
        guard !urls.isEmpty else {
            return "Drop local files to upload."
        }
        for url in urls {
            guard url.isFileURL else {
                return "Only local files can be uploaded to S3."
            }
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return "\(url.lastPathComponent) no longer exists."
            }
            if isDirectory.boolValue {
                return "Folder upload is not supported yet. Choose one or more files."
            }
        }
        return nil
    }

    static func downloadRejectionReason(for items: [S3Item]) -> String? {
        guard !items.isEmpty else {
            return "Select one or more S3 objects to download."
        }
        if items.contains(where: \.isPrefix) {
            return "S3 prefixes and buckets cannot be downloaded in this version."
        }
        return nil
    }
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
    case noSuchObject(String)
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
        case .noSuchObject(let key):
            return "Object \(key) does not exist or is not visible to this profile."
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

        if lower.contains("nosuchkey") || lower.contains("no such key") || lower.contains("not found") && bucket == nil {
            return .noSuchObject("Unknown")
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

        if nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError) {
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
    func uploadObject(request: S3UploadRequest, progress: S3TransferProgressHandler?) async throws -> S3UploadResponse
    func downloadObject(request: S3DownloadRequest, progress: S3TransferProgressHandler?) async throws -> S3DownloadResponse
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

    func upload(
        localFileURLs: [URL],
        to location: S3Location,
        profile: AWSProfile?,
        storageClass: S3StorageClass,
        progress: S3TransferProgressHandler? = nil
    ) async throws -> [S3UploadResult] {
        try Self.checkCancellation()
        if let rejection = S3TransferValidator.uploadRejectionReason(localFileURLs: localFileURLs, to: location) {
            throw S3BrowserError.permission(rejection)
        }
        let transferLocation = try await resolvedTransferLocation(location, profile: profile)
        guard let bucket = transferLocation.bucket, !bucket.isEmpty else {
            throw S3BrowserError.noBucketSelected
        }

        var results: [S3UploadResult] = []
        for (index, fileURL) in localFileURLs.enumerated() {
            try Self.checkCancellation()
            let source = try await Self.uploadSourceInfo(for: fileURL)
            let request = S3UploadRequest(
                location: transferLocation,
                sourceURL: fileURL.standardizedFileURL,
                bucket: bucket,
                key: Self.uploadKey(prefix: transferLocation.prefix, fileName: fileURL.lastPathComponent),
                storageClass: storageClass,
                contentType: source.contentType,
                contentLength: source.contentLength
            )

            progress?(S3TransferProgress(
                operation: .upload,
                fileName: fileURL.lastPathComponent,
                completedBytes: 0,
                totalBytes: source.contentLength,
                completedFiles: index,
                totalFiles: localFileURLs.count
            ))

            do {
                let response = try await gateway.uploadObject(request: request) { update in
                    progress?(S3TransferProgress(
                        operation: .upload,
                        fileName: update.fileName,
                        completedBytes: update.completedBytes,
                        totalBytes: update.totalBytes,
                        completedFiles: index,
                        totalFiles: localFileURLs.count
                    ))
                }
                try Self.checkCancellation()
                results.append(S3UploadResult(request: request, response: response))
                progress?(S3TransferProgress(
                    operation: .upload,
                    fileName: fileURL.lastPathComponent,
                    completedBytes: source.contentLength,
                    totalBytes: source.contentLength,
                    completedFiles: index + 1,
                    totalFiles: localFileURLs.count
                ))
            } catch {
                throw S3BrowserError.classify(error, bucket: bucket, requestedRegion: transferLocation.regionOverride)
            }
        }
        return results
    }

    func download(
        items: [S3Item],
        to destination: S3DownloadDestination,
        profile: AWSProfile?,
        progress: S3TransferProgressHandler? = nil,
        fileManager: FileManager = .default
    ) async throws -> [S3DownloadResult] {
        try Self.checkCancellation()
        if let rejection = S3TransferValidator.downloadRejectionReason(for: items) {
            throw S3BrowserError.permission(rejection)
        }
        if items.count > 1, case .file = destination {
            throw S3BrowserError.permission("Choose a destination folder when downloading multiple S3 objects.")
        }
        guard let first = items.first else { return [] }
        let transferLocation = try await resolvedTransferLocation(first.location, profile: profile)
        guard let bucket = transferLocation.bucket, !bucket.isEmpty else {
            throw S3BrowserError.noBucketSelected
        }

        var results: [S3DownloadResult] = []
        for (index, item) in items.enumerated() {
            try Self.checkCancellation()
            let destinationURL = await Self.destinationURL(
                for: item,
                destination: destination,
                fileManager: fileManager
            )
            let temporaryURL = Self.temporaryDownloadURL(for: destinationURL)
            let request = S3DownloadRequest(
                location: S3Location(
                    profileName: transferLocation.profileName,
                    regionOverride: transferLocation.regionOverride,
                    bucket: item.bucket,
                    prefix: item.key
                ),
                bucket: item.bucket,
                key: item.key,
                temporaryURL: temporaryURL
            )

            progress?(S3TransferProgress(
                operation: .download,
                fileName: item.name,
                completedBytes: 0,
                totalBytes: item.size,
                completedFiles: index,
                totalFiles: items.count
            ))

            do {
                let response = try await gateway.downloadObject(request: request) { update in
                    progress?(S3TransferProgress(
                        operation: .download,
                        fileName: update.fileName,
                        completedBytes: update.completedBytes,
                        totalBytes: update.totalBytes,
                        completedFiles: index,
                        totalFiles: items.count
                    ))
                }
                try Self.checkCancellation()
                try await Self.installDownloadedFile(from: temporaryURL, to: destinationURL, fileManager: fileManager)
                results.append(S3DownloadResult(item: item, destinationURL: destinationURL, bytesWritten: response.bytesWritten))
                progress?(S3TransferProgress(
                    operation: .download,
                    fileName: item.name,
                    completedBytes: response.bytesWritten,
                    totalBytes: item.size ?? response.bytesWritten,
                    completedFiles: index + 1,
                    totalFiles: items.count
                ))
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw S3BrowserError.classify(error, bucket: item.bucket, requestedRegion: transferLocation.regionOverride)
            }
        }
        return results
    }

    private struct UploadSourceInfo {
        let contentType: String?
        let contentLength: Int64
    }

    private func resolvedTransferLocation(_ location: S3Location, profile: AWSProfile?) async throws -> S3Location {
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
            continuationToken: nil
        )
        return S3Location(
            profileName: profileName,
            regionOverride: region,
            bucket: bucket,
            prefix: location.prefix
        )
    }

    private static func uploadSourceInfo(for url: URL) async throws -> UploadSourceInfo {
        try await Task.detached(priority: .userInitiated) {
            let fileURL = url.standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                throw S3BrowserError.permission("\(fileURL.lastPathComponent) no longer exists.")
            }
            guard !isDirectory.boolValue else {
                throw S3BrowserError.permission("Folder upload is not supported yet. Choose one or more files.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let contentType = fileURL.pathExtension.isEmpty
                ? nil
                : UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            return UploadSourceInfo(contentType: contentType, contentLength: size)
        }.value
    }

    static func uploadKey(prefix: String, fileName: String) -> String {
        let cleanedName = fileName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPrefix = S3Location.normalizedPrefix(prefix, isFolder: true)
        return normalizedPrefix + cleanedName
    }

    private static func destinationURL(
        for item: S3Item,
        destination: S3DownloadDestination,
        fileManager: FileManager
    ) async -> URL {
        await Task.detached(priority: .userInitiated) {
            switch destination {
            case .file(let url):
                return url.standardizedFileURL
            case .directory(let directory):
                let baseName = item.name.isEmpty ? (item.key as NSString).lastPathComponent : item.name
                return uniqueNonConflictingURL(
                    in: directory.standardizedFileURL,
                    preferredFileName: baseName,
                    fileManager: fileManager
                )
            }
        }.value
    }

    private static func uniqueNonConflictingURL(in directory: URL, preferredFileName: String, fileManager: FileManager) -> URL {
        let fileName = preferredFileName.isEmpty ? "download" : preferredFileName
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let suffix = " copy" + (index == 2 ? "" : " \(index)")
            let nextName = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            index += 1
        }
        return candidate
    }

    private static func temporaryDownloadURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".grove-download-\(UUID().uuidString)-\(destinationURL.lastPathComponent)", isDirectory: false)
    }

    private static func installDownloadedFile(from temporaryURL: URL, to destinationURL: URL, fileManager: FileManager) async throws {
        try await Task.detached(priority: .userInitiated) {
            let parent = destinationURL.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: parent.path) else {
                throw S3BrowserError.permission("The destination folder does not exist.")
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        }.value
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
