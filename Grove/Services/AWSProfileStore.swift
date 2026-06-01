import Foundation

struct AWSProfile: Identifiable, Equatable {
    let name: String
    var region: String?
    var sourceProfile: String?
    var ssoSessionName: String?
    var hasStaticCredentials: Bool
    var hasSessionToken: Bool
    var hasSSOConfiguration: Bool

    var id: String { name }

    var regionHint: String? {
        region?.isEmpty == false ? region : nil
    }
}

struct AWSProfileStore {
    let configURL: URL
    let credentialsURL: URL

    init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config"),
        credentialsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/credentials")
    ) {
        self.configURL = configURL
        self.credentialsURL = credentialsURL
    }

    func profiles() -> [AWSProfile] {
        Self.profiles(configData: try? Data(contentsOf: configURL), credentialsData: try? Data(contentsOf: credentialsURL))
    }

    static func profiles(configData: Data?, credentialsData: Data?) -> [AWSProfile] {
        let config = AWSINIParser.parse(data: configData)
        let credentials = AWSINIParser.parse(data: credentialsData)
        var profileNames = Set<String>()

        for section in config.keys {
            if let profile = profileName(fromConfigSection: section) {
                profileNames.insert(profile)
            }
        }
        for section in credentials.keys where !section.hasPrefix("sso-session ") {
            profileNames.insert(section)
        }

        return profileNames.sorted { lhs, rhs in
            if lhs == "default" { return true }
            if rhs == "default" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.map { name in
            let configSection = name == "default" ? "default" : "profile \(name)"
            let configValues = config[configSection] ?? [:]
            let credentialValues = credentials[name] ?? [:]
            let region = configValues["region"] ?? credentialValues["region"]

            return AWSProfile(
                name: name,
                region: clean(region),
                sourceProfile: clean(configValues["source_profile"] ?? credentialValues["source_profile"]),
                ssoSessionName: clean(configValues["sso_session"]),
                hasStaticCredentials: clean(credentialValues["aws_access_key_id"]) != nil &&
                    clean(credentialValues["aws_secret_access_key"]) != nil,
                hasSessionToken: clean(credentialValues["aws_session_token"]) != nil,
                hasSSOConfiguration: clean(configValues["sso_start_url"]) != nil ||
                    clean(configValues["sso_session"]) != nil ||
                    clean(configValues["sso_account_id"]) != nil ||
                    clean(configValues["sso_role_name"]) != nil
            )
        }
    }

    private static func profileName(fromConfigSection section: String) -> String? {
        if section == "default" { return "default" }
        if section.hasPrefix("profile ") {
            return clean(String(section.dropFirst("profile ".count)))
        }
        return nil
    }

    private static func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == true ? nil : cleaned
    }
}

enum AWSINIParser {
    static func parse(data: Data?) -> [String: [String: String]] {
        guard let data,
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return [:]
        }

        var sections: [String: [String: String]] = [:]
        var currentSection: String?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                currentSection = name
                sections[name, default: [:]] = sections[name] ?? [:]
                continue
            }

            guard let currentSection,
                  let separator = line.firstIndex(of: "=") ?? line.firstIndex(of: ":") else { continue }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            sections[currentSection, default: [:]][key] = value
        }

        return sections
    }

    private static func stripComment(from line: String) -> String {
        var previousWasWhitespace = true
        for index in line.indices {
            let character = line[index]
            if (character == "#" || character == ";"), previousWasWhitespace {
                return String(line[..<index])
            }
            previousWasWhitespace = character.isWhitespace
        }
        return line
    }
}
