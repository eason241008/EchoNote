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
    func testExplicitDownloadValidatesAndBecomesReady() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let folder = modelFolder(in: rootURL)
        let manager = SpeechModelManager(
            modelsRootURL: rootURL,
            downloader: StubModelDownloader(modelFolder: folder),
            validator: StubModelValidator(error: nil)
        )

        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.isReady)
        try await manager.downloadAfterUserConfirmation()

        XCTAssertEqual(manager.state, .ready(folder))
        XCTAssertTrue(manager.isReady)
    }

    @MainActor
    func testRemoveDeletesInstalledModelAndClearsReadiness() async throws {
        let rootURL = temporaryRoot()
        let folder = modelFolder(in: rootURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let manager = SpeechModelManager(
            modelsRootURL: rootURL,
            downloader: StubModelDownloader(modelFolder: folder),
            validator: StubModelValidator(error: nil)
        )
        await manager.refresh()
        XCTAssertTrue(manager.isReady)

        try await manager.remove()

        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testFailedValidationNeverReportsReady() async {
        enum ExpectedFailure: Error { case invalid }
        let rootURL = temporaryRoot()
        let folder = modelFolder(in: rootURL)
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
        let descriptor = SpeechModelDescriptor.nemotronStreaming1120
        XCTAssertEqual(descriptor.id, "nemotron-speech-streaming-en-0.6b-1120ms")
        XCTAssertEqual(descriptor.relativePath, "nemotron-streaming/1120ms")
        XCTAssertGreaterThan(descriptor.estimatedDownloadBytes, 0)
        XCTAssertGreaterThanOrEqual(descriptor.requiredFreeBytes, descriptor.estimatedDownloadBytes)
    }

    private func modelFolder(in rootURL: URL) -> URL {
        rootURL.appendingPathComponent(
            SpeechModelDescriptor.nemotronStreaming1120.relativePath,
            isDirectory: true
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-model-manager-\(UUID().uuidString)", isDirectory: true)
    }
}
