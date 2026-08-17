import AVFoundation
import XCTest
@testable import LectureAssistant

private actor PostClassStubRecognizer: LocalSpeechRecognizing {
    private var requestCount = 0

    func transcribe(samples: [Float], prompt: String?) async throws -> [SpeechRecognitionOutput] {
        requestCount += 1
        return [SpeechRecognitionOutput(
            text: "A reviewed sentence for window \(requestCount).",
            start: 0,
            end: Double(samples.count) / 16_000
        )]
    }

    func requests() -> Int { requestCount }
}

final class PostClassTranscriptionTests: XCTestCase {
    func testPostClassPassCreatesSeparateVersionedTranscriptWithoutRealtimeDatabaseWrites() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-class-transcription-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storage = SessionStorage(rootURL: rootURL)
        let sessionID = SessionID()
        try await storage.createSession(manifest: SessionManifest(
            sessionID: sessionID,
            state: .recording
        ))
        let chunkID = try await storage.beginChunk(
            sessionID: sessionID,
            sequenceNumber: 0,
            startsAt: 0,
            externalWriter: true
        )
        let stagingURL = try await storage.activeChunkStagingURL(
            sessionID: sessionID,
            chunkID: chunkID
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: stagingURL, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 32_000
        ))
        buffer.frameLength = 32_000
        for index in 0..<32_000 {
            buffer.floatChannelData?[0][index] = sin(Float(index) * 0.01) * 0.1
        }
        try file.write(from: buffer)
        _ = try await storage.finalizeChunk(
            sessionID: sessionID,
            chunkID: chunkID,
            endsAt: 2
        )

        let recognizer = PostClassStubRecognizer()
        let service = PostClassTranscriptionService(
            storage: storage,
            recognizer: recognizer,
            analysisWindowSeconds: 1
        )
        let first = try await service.generate(sessionID: sessionID, title: "Algorithms")
        let second = try await service.generate(sessionID: sessionID, title: "Algorithms")
        let saved = try await storage.postClassTranscripts(sessionID: sessionID)
        let requestCount = await recognizer.requests()

        XCTAssertEqual(first.segments.count, 2)
        XCTAssertEqual(first.segments.map(\.start), [0, 1])
        XCTAssertEqual(second.segments.count, 2)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(requestCount, 4)
    }
}
