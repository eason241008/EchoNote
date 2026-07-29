import Foundation
import XCTest
@testable import LectureAssistant
private actor RealFlowTranslationProvider: SimplifiedChineseTranslationProviding {
    let providerID = "apple-translation"
    let model = "system-on-device"

    func translate(
        _ request: SimplifiedChineseTranslationRequest
    ) async throws -> SimplifiedChineseTranslationResponse {
        try SimplifiedChineseTranslationResponse(
            translations: request.segments.map {
                try SimplifiedChineseTranslation(
                    revisionID: $0.revisionID,
                    text: "中文：\($0.text)"
                )
            },
            matching: request
        )
    }
}


final class RealLectureFlowTests: XCTestCase {
    @MainActor
    func testSpeakerToMicrophoneTranscriptionAndTranslation() async throws {
        try requireRealFlow()
        let authorization = SystemMicrophoneAuthorizationProvider()
        if authorization.status() != .authorized {
            guard await authorization.requestAccess() else {
                return XCTFail("Microphone permission was not granted to the test runner.")
            }
        }
        let device = try XCTUnwrap(CoreAudioInputDeviceProvider().inputDevices().first)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-lecture-flow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try LectureDatabase(url: root.appendingPathComponent("lecture.sqlite"))
        try database.migrate()
        let storage = SessionStorage(rootURL: root.appendingPathComponent("Sessions"))
        let captions = CaptionWorkspaceModel()
        let modelFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/课堂伴侣/Models/openai_whisper-small.en")
        let service = ProductionLectureCaptureService(
            storage: storage,
            database: database,
            modelFolder: modelFolder,
            captionWorkspace: captions,
            translationProvider: RealFlowTranslationProvider()
        )
        let lecture = LectureSession(title: "今天的课程")
        try await service.prepare(.init(session: lecture, deviceID: device.id))
        try await service.start()
        try await Task.sleep(for: .milliseconds(500))
        let speaker = Process()
        speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speaker.arguments = [
            "-v", "Samantha", "-r", "135",
            "Machine learning lecture. Machine learning uses data. This machine learning lecture explains neural networks. The lecture assistant records the lecture and translates the lecture."
        ]
        try speaker.run()
        speaker.waitUntilExit()
        XCTAssertEqual(speaker.terminationStatus, 0)
        let liveDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while captions.segments.filter({ !$0.isGap }).isEmpty,
              ContinuousClock.now < liveDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let liveTranscript = captions.segments.filter { !$0.isGap }.map(\.text).joined(separator: " ")
        XCTAssertFalse(liveTranscript.isEmpty, "No English caption appeared before recording stopped.")
        XCTAssertFalse(liveTranscript.contains("今天的课程"), "Chinese course title leaked into English ASR output.")
        try await service.stop()

        let manifest = try await storage.loadManifest(sessionID: lecture.id)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertGreaterThan(manifest.chunks[0].byteCount, 0)
        let transcript = captions.segments.filter { !$0.isGap }.map(\.text).joined(separator: " ")
        XCTAssertFalse(transcript.isEmpty, "No English transcript was produced from speaker audio.")
        XCTAssertTrue(
            transcript.localizedCaseInsensitiveContains("learning")
                || transcript.localizedCaseInsensitiveContains("lecture")
                || transcript.localizedCaseInsensitiveContains("explanation"),
            "Unexpected transcript: \(transcript)"
        )
        XCTAssertFalse(captions.translations.isEmpty, "No Simplified Chinese translation was produced.")
        XCTAssertTrue(captions.translations.values.contains { !$0.isEmpty })
        print("REAL_LECTURE_FLOW transcript=\(transcript)")
        print("REAL_LECTURE_FLOW translations=\(captions.translations.values.joined(separator: " | "))")
    }

    private func requireRealFlow() throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_LECTURE_FLOW"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_LECTURE_FLOW=1 for hardware validation.")
        }
    }

}
