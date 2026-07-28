import Foundation

@MainActor
public final class ProviderSettingsModel: ObservableObject {
    @Published public private(set) var configuration: ProviderConfiguration?
    @Published public private(set) var statusMessage: String?

    private let importer: ProviderConfigurationImporter

    public init(
        credentialStore: any ProviderCredentialStore = KeychainProviderCredentialStore(),
        defaults: UserDefaults = .standard
    ) {
        importer = ProviderConfigurationImporter(
            credentialStore: credentialStore,
            defaults: defaults
        )
        configuration = importer.configuredProvider()
    }

    public func importOMPConfiguration(
        from fileURL: URL,
        providerID: String,
        model: String
    ) {
        do {
            try importer.importOMPConfiguration(
                from: fileURL,
                providerID: providerID,
                model: model
            )
            configuration = importer.configuredProvider()
            statusMessage = "翻译服务已配置，API 密钥已安全保存到 macOS 钥匙串。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func removeConfiguration() {
        do {
            try importer.removeConfiguration()
            configuration = nil
            statusMessage = "翻译服务已关闭，应用将继续使用离线英文转写。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
