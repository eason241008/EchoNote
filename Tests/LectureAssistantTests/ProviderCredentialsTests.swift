import Foundation
import XCTest
@testable import LectureAssistant

private final class InMemoryCredentialStore: ProviderCredentialStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func credential(for providerID: String) throws -> String? {
        values[providerID]
    }

    func replaceCredential(_ credential: String, for providerID: String) throws {
        values[providerID] = credential
    }

    func removeCredential(for providerID: String) throws {
        values.removeValue(forKey: providerID)
    }
}

final class ProviderCredentialsTests: XCTestCase {
    func testImportsOpenAICompatibleOMPProvider() throws {
        let contents = """
        providers:
          openai:
            baseUrl: https://example.test/v1
            api: openai-responses
            apiKey: secret-value
            compat:
              includeEncryptedReasoning: false
        """

        let imported = try OMPProviderConfigurationImporter().importConfiguration(
            contents: contents,
            providerID: "openai",
            model: "lecture-translation-model"
        )

        XCTAssertEqual(imported.configuration.providerID, "openai")
        XCTAssertEqual(imported.configuration.baseURL.absoluteString, "https://example.test/v1")
        XCTAssertEqual(imported.configuration.model, "lecture-translation-model")
        XCTAssertEqual(imported.apiKey, "secret-value")
    }

    func testImportErrorsDoNotExposeCredential() {
        let credential = "do-not-expose-this-secret"
        let contents = """
        providers:
          openai:
            baseUrl: not-a-url
            apiKey: \(credential)
        """

        XCTAssertThrowsError(
            try OMPProviderConfigurationImporter().importConfiguration(
                contents: contents,
                providerID: "openai",
                model: "model"
            )
        ) { error in
            XCTAssertFalse(error.localizedDescription.contains(credential))
        }
    }

    @MainActor
    func testPersistsOnlyNonSecretProviderConfiguration() throws {
        let defaultsName = #function
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let credentialStore = InMemoryCredentialStore()
        let importer = ProviderConfigurationImporter(
            credentialStore: credentialStore,
            defaults: defaults
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try """
        providers:
          openai:
            baseUrl: https://example.test/v1
            apiKey: secret-value
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try importer.importOMPConfiguration(
            from: fileURL,
            providerID: "openai",
            model: "lecture-translation-model"
        )

        XCTAssertEqual(try credentialStore.credential(for: "openai"), "secret-value")
        XCTAssertEqual(importer.configuredProvider()?.model, "lecture-translation-model")
        let storedValues = defaults.dictionaryRepresentation().description
        XCTAssertFalse(storedValues.contains("secret-value"))

        try importer.removeConfiguration()
        XCTAssertNil(try credentialStore.credential(for: "openai"))
        XCTAssertNil(importer.configuredProvider())
    }
}
