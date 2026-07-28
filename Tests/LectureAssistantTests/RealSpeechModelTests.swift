import Foundation
import XCTest
@testable import LectureAssistant

final class RealSpeechModelTests: XCTestCase {
    @MainActor
    func testDownloadsValidatesAndRemovesSmallEnglishModel() async throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_MODEL"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_MODEL=1 to exercise WhisperKit download.")
        }
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-whisperkit-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let manager = SpeechModelManager(modelsRootURL: rootURL)

        try await manager.downloadAfterUserConfirmation()
        XCTAssertTrue(manager.isReady)
        if case let .ready(folder) = manager.state {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        } else {
            XCTFail("Expected ready model")
        }

        try await manager.remove()
        XCTAssertEqual(manager.state, .notInstalled)
    }
}
