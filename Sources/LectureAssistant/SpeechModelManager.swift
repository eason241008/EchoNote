import FluidAudio
import Foundation

public struct SpeechModelDescriptor: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let estimatedDownloadBytes: Int64
    public let requiredFreeBytes: Int64
    public let relativePath: String

    public static let nemotronStreaming1120 = SpeechModelDescriptor(
        id: "nemotron-speech-streaming-en-0.6b-1120ms",
        displayName: "Nemotron Streaming 0.6B · 1120 ms",
        estimatedDownloadBytes: 600_000_000,
        requiredFreeBytes: 1_500_000_000,
        relativePath: NemotronChunkSize.ms1120.repo.folderName
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

public struct FluidAudioModelDownloader: SpeechModelDownloading {
    public init() {}

    public func download(
        descriptor: SpeechModelDescriptor,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await ModelHub.download(
            .nemotronStreaming1120,
            to: destination,
            progressHandler: { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        )
        return destination.appendingPathComponent(descriptor.relativePath, isDirectory: true)
    }
}

public struct FluidAudioModelValidator: SpeechModelValidating {
    public init() {}

    public func validate(modelFolder: URL) async throws {
        let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
        try await manager.loadModels(from: modelFolder)
        await manager.cleanup()
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
        descriptor: SpeechModelDescriptor = .nemotronStreaming1120,
        modelsRootURL: URL,
        downloader: any SpeechModelDownloading = FluidAudioModelDownloader(),
        validator: any SpeechModelValidating = FluidAudioModelValidator(),
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.modelsRootURL = modelsRootURL
        self.downloader = downloader
        self.validator = validator
        self.fileManager = fileManager
        let installedURL = modelsRootURL.appendingPathComponent(
            descriptor.relativePath,
            isDirectory: true
        )
        state = fileManager.fileExists(atPath: installedURL.path) ? .verifying : .notInstalled
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public var isBusy: Bool {
        switch state {
        case .downloading, .verifying: return true
        case .notInstalled, .ready, .failed: return false
        }
    }

    public var statusText: String {
        switch state {
        case .notInstalled: return "未安装"
        case let .downloading(progress): return "下载中 · \(Int(progress * 100))%"
        case .verifying: return "正在验证"
        case .ready: return "已就绪"
        case .failed: return "验证失败"
        }
    }

    public func refresh() async {
        guard fileManager.fileExists(atPath: installedURL.path) else {
            state = .notInstalled
            return
        }
        state = .verifying
        do {
            try await validator.validate(modelFolder: installedURL)
            state = .ready(installedURL)
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
        guard fileManager.fileExists(atPath: installedURL.path) else {
            state = .notInstalled
            return
        }
        do {
            try fileManager.removeItem(at: installedURL)
            removeEmptyParentDirectories()
            state = .notInstalled
        } catch {
            state = .failed(SpeechModelManagerError.removalFailed.localizedDescription)
            throw SpeechModelManagerError.removalFailed
        }
    }

    private var installedURL: URL {
        modelsRootURL.appendingPathComponent(descriptor.relativePath, isDirectory: true)
    }

    private func removeEmptyParentDirectories() {
        var directory = installedURL.deletingLastPathComponent()
        while directory.path != modelsRootURL.path {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else { return }
            try? fileManager.removeItem(at: directory)
            directory.deleteLastPathComponent()
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
