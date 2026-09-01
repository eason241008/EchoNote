import Foundation
import WhisperKit

public struct SpeechModelDescriptor: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let estimatedDownloadBytes: Int64
    public let requiredFreeBytes: Int64

    public static let largeV3Compressed = SpeechModelDescriptor(
        id: "large-v3-v20240930_626MB",
        displayName: "WhisperKit large-v3 · 626 MB",
        estimatedDownloadBytes: 626_000_000,
        requiredFreeBytes: 2_000_000_000
    )
}

public enum SpeechModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case verifying
    case installed(URL)
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
        let fileManager = FileManager.default
        let requiredPaths = [
            "config.json",
            "generation_config.json",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
        ]
        for relativePath in requiredPaths {
            let url = modelFolder.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: url.path),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else {
                throw SpeechModelManagerError.invalidModelDirectory
            }
        }
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
        descriptor: SpeechModelDescriptor = .largeV3Compressed,
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
        state = Self.installedModelFolders(
            descriptor: descriptor,
            modelsRootURL: modelsRootURL,
            fileManager: fileManager
        ).isEmpty ? .notInstalled : .verifying
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public var readyModelFolder: URL? {
        guard case let .ready(modelFolder) = state else { return nil }
        return modelFolder
    }

    public var loadableModelFolder: URL? {
        switch state {
        case let .installed(modelFolder), let .ready(modelFolder): return modelFolder
        default: return nil
        }
    }

    public var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .installed: return true
        case .notInstalled, .ready, .failed: return false
        }
    }

    public var statusText: String {
        switch state {
        case .notInstalled: return "未安装"
        case let .downloading(progress): return "下载中 · \(Int(progress * 100))%"
        case .verifying: return "正在验证"
        case .installed: return "正在加载"
        case .ready: return "已就绪"
        case .failed: return "验证失败"
        }
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
            state = .installed(candidate)
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
            state = .installed(folder)
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

    public func markRecognizerReady(modelFolder: URL) {
        guard let installedFolder = loadableModelFolder,
              installedFolder.standardizedFileURL == modelFolder.standardizedFileURL else { return }
        state = .ready(installedFolder)
    }

    public func markRecognizerFailed(_ error: Error) {
        state = .failed(error.localizedDescription)
    }

    private func installedCandidates() -> [URL] {
        Self.installedModelFolders(
            descriptor: descriptor,
            modelsRootURL: modelsRootURL,
            fileManager: fileManager
        )
    }

    nonisolated static func installedModelFolders(
        descriptor: SpeechModelDescriptor = .largeV3Compressed,
        modelsRootURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let folderName = "openai_whisper-\(descriptor.id)"
        let expectedLocations = [
            modelsRootURL.appendingPathComponent(folderName, isDirectory: true),
            modelsRootURL
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true),
        ]
        let existingExpectedLocations = expectedLocations.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        if !existingExpectedLocations.isEmpty { return existingExpectedLocations }

        guard let enumerator = fileManager.enumerator(
            at: modelsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent == folderName
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
