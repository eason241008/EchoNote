import Foundation
import Security

public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public var providerID: String
    public var baseURL: URL
    public var model: String

    public init(providerID: String, baseURL: URL, model: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
    }
}

public struct ImportedProviderConfiguration: Equatable, Sendable {
    public var configuration: ProviderConfiguration
    public var apiKey: String

    public init(configuration: ProviderConfiguration, apiKey: String) {
        self.configuration = configuration
        self.apiKey = apiKey
    }
}

public enum CredentialStoreError: LocalizedError, Equatable {
    case invalidCredential
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "The provider credential is empty."
        case .keychainFailure:
            return "The provider credential could not be updated in macOS Keychain."
        }
    }
}

public protocol ProviderCredentialStore: Sendable {
    func credential(for providerID: String) throws -> String?
    func replaceCredential(_ credential: String, for providerID: String) throws
    func removeCredential(for providerID: String) throws
}

public struct KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String

    public init(service: String = "com.lectureassistant.provider-credentials") {
        self.service = service
    }

    public func credential(for providerID: String) throws -> String? {
        var query = baseQuery(providerID: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.keychainFailure(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func replaceCredential(_ credential: String, for providerID: String) throws {
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = credential.data(using: .utf8) else {
            throw CredentialStoreError.invalidCredential
        }

        let query = baseQuery(providerID: providerID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(addStatus)
        }
    }

    public func removeCredential(for providerID: String) throws {
        let status = SecItemDelete(baseQuery(providerID: providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

public enum OMPConfigurationImportError: LocalizedError, Equatable {
    case unreadableFile
    case providerNotFound
    case missingBaseURL
    case invalidBaseURL
    case missingModel
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .unreadableFile: return "The selected OMP configuration could not be read."
        case .providerNotFound: return "The selected provider was not found in the OMP configuration."
        case .missingBaseURL: return "The selected provider does not define a Base URL."
        case .invalidBaseURL: return "The selected provider has an invalid Base URL."
        case .missingModel: return "A model name is required for the imported provider."
        case .missingAPIKey: return "The selected provider does not contain an API key."
        }
    }
}

public struct OMPProviderConfigurationImporter: Sendable {
    public init() {}

    public func importConfiguration(
        from fileURL: URL,
        providerID: String,
        model: String
    ) throws -> ImportedProviderConfiguration {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw OMPConfigurationImportError.unreadableFile
        }
        return try importConfiguration(contents: contents, providerID: providerID, model: model)
    }

    public func importConfiguration(
        contents: String,
        providerID: String,
        model: String
    ) throws -> ImportedProviderConfiguration {
        let values = try providerValues(in: contents, providerID: providerID)
        guard let baseURLValue = values["baseUrl"], !baseURLValue.isEmpty else {
            throw OMPConfigurationImportError.missingBaseURL
        }
        guard let baseURL = URL(string: baseURLValue), baseURL.scheme != nil else {
            throw OMPConfigurationImportError.invalidBaseURL
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { throw OMPConfigurationImportError.missingModel }
        guard let apiKey = values["apiKey"], !apiKey.isEmpty else {
            throw OMPConfigurationImportError.missingAPIKey
        }

        return ImportedProviderConfiguration(
            configuration: ProviderConfiguration(
                providerID: providerID,
                baseURL: baseURL,
                model: normalizedModel
            ),
            apiKey: apiKey
        )
    }

    private func providerValues(in contents: String, providerID: String) throws -> [String: String] {
        let normalized = contents.replacingOccurrences(of: "\u{feff}", with: "")
        var inProviders = false
        var inSelectedProvider = false
        var values: [String: String] = [:]

        for rawLine in normalized.split(whereSeparator: \ .isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indentation = line.prefix { $0 == " " }.count

            if indentation == 0 {
                inProviders = trimmed == "providers:"
                inSelectedProvider = false
                continue
            }
            guard inProviders else { continue }

            if indentation == 2, trimmed.hasSuffix(":") {
                let name = String(trimmed.dropLast())
                if inSelectedProvider && name != providerID { break }
                inSelectedProvider = name == providerID
                continue
            }
            guard inSelectedProvider, indentation >= 4,
                  let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator])
            var value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }

        guard inSelectedProvider || !values.isEmpty else {
            throw OMPConfigurationImportError.providerNotFound
        }
        return values
    }
}

@MainActor
public struct ProviderConfigurationImporter {
    private let credentialStore: any ProviderCredentialStore
    private let defaults: UserDefaults
    private let ompImporter: OMPProviderConfigurationImporter
    private let configurationKey = "lecture-assistant.translation-provider"

    public init(
        credentialStore: any ProviderCredentialStore,
        defaults: UserDefaults = .standard,
        ompImporter: OMPProviderConfigurationImporter = OMPProviderConfigurationImporter()
    ) {
        self.credentialStore = credentialStore
        self.defaults = defaults
        self.ompImporter = ompImporter
    }

    public func importOMPConfiguration(from fileURL: URL, providerID: String, model: String) throws {
        let imported = try ompImporter.importConfiguration(
            from: fileURL,
            providerID: providerID,
            model: model
        )
        try credentialStore.replaceCredential(imported.apiKey, for: providerID)
        defaults.set(try JSONEncoder().encode(imported.configuration), forKey: configurationKey)
    }

    public func configuredProvider() -> ProviderConfiguration? {
        guard let data = defaults.data(forKey: configurationKey) else { return nil }
        return try? JSONDecoder().decode(ProviderConfiguration.self, from: data)
    }

    public func removeConfiguration() throws {
        if let configuration = configuredProvider() {
            try credentialStore.removeCredential(for: configuration.providerID)
        }
        defaults.removeObject(forKey: configurationKey)
    }
}
