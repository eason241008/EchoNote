import Foundation
import XCTest
@testable import LectureAssistant

final class RealLectureFlowTests: XCTestCase {
    @MainActor
    func testConfiguredTranslationProviderDirectly() async throws {
        try requireRealFlow()
        let provider = try configuredProviderFromEnvironment()
        let revisionID = TranscriptRevisionID()
        let request = try SimplifiedChineseTranslationRequest(
            segments: [try TranslationSourceSegment(
                revisionID: revisionID,
                text: "The lecture explains machine learning."
            )]
        )
        let response = try await provider.translate(request)
        XCTAssertEqual(response.translations.map(\.revisionID), [revisionID])
        XCTAssertFalse(response.translations[0].text.isEmpty)
        print("REAL_TRANSLATION_PROVIDER text=\(response.translations[0].text)")

        let pipeline = TranslationPipeline(provider: provider, batchingDelay: .milliseconds(10))
        let resultTask = Task { () -> SimplifiedChineseTranslation? in
            for await result in pipeline.results { return result }
            return nil
        }
        await pipeline.enqueue(.init(
            sessionID: SessionID(),
            revisionID: revisionID,
            text: "The lecture explains machine learning."
        ))
        try await Task.sleep(for: .seconds(5))
        await pipeline.finish()
        let pipelineResult = await resultTask.value
        XCTAssertEqual(pipelineResult?.revisionID, revisionID)
        XCTAssertFalse(pipelineResult?.text.isEmpty ?? true)
    }

    func testURLSessionTransportDiagnostics() async throws {
        try requireRealFlow()
        let environment = ProcessInfo.processInfo.environment
        let baseURL = try XCTUnwrap(environment["LECTURE_ASSISTANT_TRANSLATION_BASE_URL"])
        let apiKey = try XCTUnwrap(environment["LECTURE_ASSISTANT_TRANSLATION_API_KEY"])
        let url = try XCTUnwrap(URL(string: baseURL)?.appendingPathComponent("chat/completions"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LectureAssistant/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.6-sol",
            "response_format": ["type": "json_object"],
            "messages": [["role": "user", "content": "Return JSON with a translation of machine learning."]],
        ])
        let session = TranslationURLSessionFactory.session(for: try XCTUnwrap(URL(string: baseURL)))
        do {
            let (data, response) = try await session.data(for: request)
            print("REAL_URLSESSION status=\((response as? HTTPURLResponse)?.statusCode ?? -1) bytes=\(data.count)")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } catch let error as URLError {
            XCTFail("URLSession transport failed code=\(error.code.rawValue) \(error.localizedDescription)")
        }
    }

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
        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: "com.ohmypi.lectureassistant"))
        let captions = CaptionWorkspaceModel(defaults: appDefaults)
        let modelFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/课堂伴侣/Models/openai_whisper-small.en")
        let service = ProductionLectureCaptureService(
            storage: storage,
            database: database,
            modelFolder: modelFolder,
            captionWorkspace: captions,
            defaults: appDefaults,
            translationProviderOverride: try configuredProviderFromEnvironment()
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
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_LECTURE_FLOW=1 for hardware and provider validation.")
        }
    }

    private func configuredProviderFromEnvironment() throws -> OpenAICompatibleTranslationProvider {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = try XCTUnwrap(environment["LECTURE_ASSISTANT_TRANSLATION_BASE_URL"])
        let apiKey = try XCTUnwrap(environment["LECTURE_ASSISTANT_TRANSLATION_API_KEY"])
        return OpenAICompatibleTranslationProvider(
            configuration: ProviderConfiguration(
                providerID: "real-test",
                baseURL: try XCTUnwrap(URL(string: baseURL)),
                model: "gpt-5.6-sol"
            ),
            apiKey: apiKey,
            session: TranslationURLSessionFactory.session(for: try XCTUnwrap(URL(string: baseURL)))
        )
    }
}
