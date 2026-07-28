import Foundation
import WhisperKit

public struct SpeechModelDescriptor: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let estimatedDownloadBytes: Int64
    public let requiredFreeBytes: Int64

    public static let smallEnglish = SpeechModelDescriptor(
        id: "small.en",
        displayName: "Whisper small.en",
        estimatedDownloadBytes: 500_000_000,
        requiredFreeBytes: 1_000_000_000
    )
}

public enum SpeechModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case verifying
    case ready(URL)
    case failed(String)
}

public protocol SpeechModelDownloading: Sendable {
    func download(
        descriptor: SpeechModelDescriptor,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

public protocol SpeechModelValidating: Sendable {
    func validate(modelFolder: URL) async throws
}

public struct WhisperKitModelDownloader: SpeechModelDownloading {
    public init() {}

    public func download(
        descriptor: SpeechModelDescriptor,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: descriptor.id,
            downloadBase: destination,
            progressCallback: { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        )
    }
}

public struct WhisperKitModelValidator: SpeechModelValidating {
    public init() {}

    public func validate(modelFolder: URL) async throws {
        let config = WhisperKitConfig(
            model: SpeechModelDescriptor.smallEnglish.id,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        _ = try await WhisperKit(config)
    }
}

public enum SpeechModelManagerError: LocalizedError, Equatable {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidModelDirectory
    case removalFailed

    public var errorDescription: String? {
        switch self {
        case let .insufficientDiskSpace(required, available):
            return "The speech model requires \(required) bytes but only \(available) bytes are available."
        case .invalidModelDirectory:
            return "The downloaded speech model failed validation."
        case .removalFailed:
            return "The speech model could not be removed."
        }
    }
}

@MainActor
public final class SpeechModelManager: ObservableObject {
    @Published public private(set) var state: SpeechModelState

    public let descriptor: SpeechModelDescriptor
    private let modelsRootURL: URL
    private let downloader: any SpeechModelDownloading
    private let validator: any SpeechModelValidating
    private let fileManager: FileManager

    public init(
        descriptor: SpeechModelDescriptor = .smallEnglish,
        modelsRootURL: URL,
        downloader: any SpeechModelDownloading = WhisperKitModelDownloader(),
        validator: any SpeechModelValidating = WhisperKitModelValidator(),
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.modelsRootURL = modelsRootURL
        self.downloader = downloader
        self.validator = validator
        self.fileManager = fileManager
        let installedURL = modelsRootURL.appendingPathComponent("openai_whisper-\(descriptor.id)")
        state = fileManager.fileExists(atPath: installedURL.path) ? .verifying : .notInstalled
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public func refresh() async {
        let candidates = installedCandidates()
        guard let candidate = candidates.first else {
            state = .notInstalled
            return
        }
        state = .verifying
        do {
            try await validator.validate(modelFolder: candidate)
            state = .ready(candidate)
        } catch {
            state = .failed(SpeechModelManagerError.invalidModelDirectory.localizedDescription)
        }
    }

    public func downloadAfterUserConfirmation() async throws {
        let available = try availableCapacity(at: modelsRootURL)
        guard available >= descriptor.requiredFreeBytes else {
            let error = SpeechModelManagerError.insufficientDiskSpace(
                required: descriptor.requiredFreeBytes,
                available: available
            )
            state = .failed(error.localizedDescription)
            throw error
        }
        try fileManager.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
        state = .downloading(0)
        do {
            let folder = try await downloader.download(
                descriptor: descriptor,
                destination: modelsRootURL,
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.state = .downloading(min(1, max(0, fraction)))
                    }
                }
            )
            state = .verifying
            try await validator.validate(modelFolder: folder)
            state = .ready(folder)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func remove() async throws {
        for candidate in installedCandidates() {
            do {
                try fileManager.removeItem(at: candidate)
            } catch {
                state = .failed(SpeechModelManagerError.removalFailed.localizedDescription)
                throw SpeechModelManagerError.removalFailed
            }
        }
        state = .notInstalled
    }

    private func installedCandidates() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: modelsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent == "openai_whisper-\(descriptor.id)"
        }
    }

    private func availableCapacity(at url: URL) throws -> Int64 {
        var probe = url
        while !fileManager.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
