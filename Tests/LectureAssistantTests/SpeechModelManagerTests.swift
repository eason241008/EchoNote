import Foundation
import XCTest
@testable import LectureAssistant

private actor StubModelDownloader: SpeechModelDownloading {
    let modelFolder: URL

    init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    func download(
        descriptor: SpeechModelDescriptor,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        progress(0.25)
        progress(1)
        return modelFolder
    }
}

private struct StubModelValidator: SpeechModelValidating {
    let error: Error?

    func validate(modelFolder: URL) async throws {
        if let error { throw error }
    }
}

final class SpeechModelManagerTests: XCTestCase {
    @MainActor
    func testExplicitDownloadRequiresRecognizerPrewarmBeforeBecomingReady() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let folder = rootURL.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB")
        let manager = SpeechModelManager(
            modelsRootURL: rootURL,
            downloader: StubModelDownloader(modelFolder: folder),
            validator: StubModelValidator(error: nil)
        )

        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.isReady)
        try await manager.downloadAfterUserConfirmation()

        XCTAssertEqual(manager.state, .installed(folder))
        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(manager.loadableModelFolder, folder)

        manager.markRecognizerReady(modelFolder: folder)
        XCTAssertEqual(manager.state, .ready(folder))
        XCTAssertTrue(manager.isReady)
    }

    @MainActor
    func testRemoveDeletesInstalledModelAndClearsReadiness() async throws {
        let rootURL = temporaryRoot()
        let folder = rootURL.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let manager = SpeechModelManager(
            modelsRootURL: rootURL,
            downloader: StubModelDownloader(modelFolder: folder),
            validator: StubModelValidator(error: nil)
        )
        await manager.refresh()
        manager.markRecognizerReady(modelFolder: folder)
        XCTAssertTrue(manager.isReady)

        try await manager.remove()

        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testRefreshExposesWhisperKitNestedDownloadFolderToRuntime() async throws {
        let rootURL = temporaryRoot()
        let folder = rootURL
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-large-v3-v20240930_626MB", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let manager = SpeechModelManager(
            modelsRootURL: rootURL,
            downloader: StubModelDownloader(modelFolder: folder),
            validator: StubModelValidator(error: nil)
        )

        XCTAssertEqual(manager.state, .verifying)
        await manager.refresh()

        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(
            manager.loadableModelFolder?.resolvingSymlinksInPath(),
            folder.resolvingSymlinksInPath()
        )
    }

    @MainActor
    func testFailedValidationNeverReportsReady() async {
        enum ExpectedFailure: Error { case invalid }
        let rootURL = temporaryRoot()
        let folder = rootURL.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let manager = SpeechModelManager(
            modelsRootURL: rootURL,
            downloader: StubModelDownloader(modelFolder: folder),
            validator: StubModelValidator(error: ExpectedFailure.invalid)
        )

        do {
            try await manager.downloadAfterUserConfirmation()
            XCTFail("Expected validation failure")
        } catch {
            XCTAssertEqual(error as? ExpectedFailure, .invalid)
        }
        XCTAssertFalse(manager.isReady)
        if case .failed = manager.state {} else {
            XCTFail("Expected failed state")
        }
    }

    @MainActor
    func testDescriptorDisclosesDownloadAndDiskRequirements() {
        let descriptor = SpeechModelDescriptor.largeV3Compressed
        XCTAssertEqual(descriptor.id, "large-v3-v20240930_626MB")
        XCTAssertGreaterThan(descriptor.estimatedDownloadBytes, 0)
        XCTAssertGreaterThanOrEqual(descriptor.requiredFreeBytes, descriptor.estimatedDownloadBytes)
    }

    func testProductionValidatorChecksModelStructureWithoutLoadingWhisperKit() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let requiredPaths = [
            "config.json",
            "generation_config.json",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
        ]
        for relativePath in requiredPaths {
            let url = rootURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: url)
        }

        try await WhisperKitModelValidator().validate(modelFolder: rootURL)

        try FileManager.default.removeItem(
            at: rootURL.appendingPathComponent("MelSpectrogram.mlmodelc/coremldata.bin")
        )
        do {
            try await WhisperKitModelValidator().validate(modelFolder: rootURL)
            XCTFail("Expected an incomplete model to fail validation")
        } catch {
            XCTAssertEqual(error as? SpeechModelManagerError, .invalidModelDirectory)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-model-manager-\(UUID().uuidString)", isDirectory: true)
    }
}
