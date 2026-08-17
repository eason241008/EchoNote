import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

private actor StubSpeechRecognizer: LocalSpeechRecognizing {
    enum Behavior {
        case output(String)
        case outputs([SpeechRecognitionOutput])
        case empty
        case failure
    }
    var behavior: Behavior
    let delay: Duration?
    private(set) var prompts: [String?] = []

    init(behavior: Behavior, delay: Duration? = nil) {
        self.behavior = behavior
        self.delay = delay
    }

    func transcribe(samples: [Float], prompt: String?) async throws -> [SpeechRecognitionOutput] {
        if let delay { try? await Task.sleep(for: delay) }
        prompts.append(prompt)
        switch behavior {
        case let .output(text):
            return [SpeechRecognitionOutput(
                text: text,
                start: 0,
                end: Double(samples.count) / 16_000
            )]
        case let .outputs(outputs):
            return outputs
        case .empty:
            return []
        case .failure:
            throw NSError(domain: "StubSpeechRecognizer", code: 1)
        }
    }

    func latestPrompt() -> String? { prompts.last ?? nil }

    func setBehavior(_ behavior: Behavior) { self.behavior = behavior }
}

final class LiveTranscriptionTests: XCTestCase {
    func testPublishesPartialThenFinalAndPersistsFinalRevision() async throws {
        let fixture = try await makeFixture()
        await fixture.pipeline.updatePrompt("neural network")
        let collector = Task { () -> [LiveTranscriptSegment] in
            var values: [LiveTranscriptSegment] = []
            for await segment in fixture.pipeline.segments { values.append(segment) }
            return values
        }
        let latencyCollector = Task { () -> [CaptionLatencyStatus] in
            var values: [CaptionLatencyStatus] = []
            for await status in fixture.pipeline.latencyStatuses { values.append(status) }
            return values
        }

        await fixture.pipeline.consume(try frame(samples: 16_000))
        await fixture.pipeline.consume(try frame(samples: 16_000))
        await fixture.pipeline.finish()
        let segments = await collector.value
        let latencyStatuses = await latencyCollector.value

        XCTAssertTrue(segments.contains { !$0.isFinal && !$0.isGap })
        let finalized = try XCTUnwrap(segments.last { $0.isFinal && !$0.isGap })
        let stored = try await MainActor.run {
            try fixture.repository.history(sessionID: fixture.session.id, segmentID: finalized.id)
        }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].text, "recognized lecture")
        let latestPrompt = await fixture.recognizer.latestPrompt()
        XCTAssertEqual(latestPrompt, "neural network")
        XCTAssertFalse(latencyStatuses.isEmpty)
        XCTAssertGreaterThanOrEqual(latencyStatuses.last!.latestSeconds, 0)
    }

    func testPromptAcceptsEnglishTerminologyAndRejectsChineseCourseTitle() async throws {
        XCTAssertNil(LiveTranscriptionPipeline.englishPrompt(from: "今天的课程"))
        XCTAssertEqual(
            LiveTranscriptionPipeline.englishPrompt(from: "machine learning"),
            "machine learning"
        )
    }

    func testEmptyRecognitionIsTreatedAsSilenceInsteadOfMissingAudio() async throws {
        let fixture = try await makeFixture(behavior: .empty)
        let collector = Task { () -> [LiveTranscriptSegment] in
            var values: [LiveTranscriptSegment] = []
            for await segment in fixture.pipeline.segments { values.append(segment) }
            return values
        }

        await fixture.pipeline.consume(try frame(samples: 32_000))
        await fixture.pipeline.finish()

        let segments = await collector.value
        XCTAssertTrue(segments.isEmpty)
    }

    func testOutputsWithinOneWindowAreMergedAcrossShortPauses() async throws {
        let outputs = [
            SpeechRecognitionOutput(text: "This is a clause", start: 0, end: 1.4),
            SpeechRecognitionOutput(text: "that continues after a pause.", start: 1.8, end: 3.2),
        ]
        let fixture = try await makeFixture(behavior: .outputs(outputs))
        let collector = Task { () -> [LiveTranscriptSegment] in
            var values: [LiveTranscriptSegment] = []
            for await segment in fixture.pipeline.segments where segment.isFinal {
                values.append(segment)
            }
            return values
        }

        await fixture.pipeline.consume(try frame(samples: 32_000))
        await fixture.pipeline.finish()
        let finalized = await collector.value

        XCTAssertEqual(finalized.count, 1)
        XCTAssertEqual(finalized[0].text, "This is a clause that continues after a pause.")
        XCTAssertEqual(finalized[0].start, 0)
        XCTAssertEqual(finalized[0].end, 3.2)
    }

    func testParagraphsContainAtMostTwoSentences() {
        let outputs = [SpeechRecognitionOutput(
            text: "First sentence. Second sentence. Third sentence! Fourth sentence? Fifth sentence.",
            start: 0,
            end: 10
        )]

        let paragraphs = LiveTranscriptionPipeline.paragraphOutputs(outputs)

        XCTAssertEqual(paragraphs.map(\.text), [
            "First sentence. Second sentence.",
            "Third sentence! Fourth sentence?",
            "Fifth sentence.",
        ])
        XCTAssertEqual(paragraphs.first?.start, 0)
        XCTAssertEqual(paragraphs.last?.end, 10)
    }

    func testRecognitionFailureCreatesExplicitGapRevision() async throws {
        let fixture = try await makeFixture(behavior: .failure)
        let collector = Task { () -> [LiveTranscriptSegment] in
            var values: [LiveTranscriptSegment] = []
            for await segment in fixture.pipeline.segments { values.append(segment) }
            return values
        }

        await fixture.pipeline.consume(try frame(samples: 16_000))
        await fixture.pipeline.finish()
        let segments = await collector.value
        let gap = try XCTUnwrap(segments.first { $0.isGap })

        let stored = try await MainActor.run {
            try fixture.repository.history(sessionID: fixture.session.id, segmentID: gap.id)
        }
        XCTAssertEqual(stored.count, 1)
        XCTAssertGreaterThan(stored[0].end, stored[0].start)
    }

    func testSlowRecognitionDoesNotBlockAudioIngestionOrLoseFinalWindows() async throws {
        let fixture = try await makeFixture(delay: .milliseconds(250))
        let collector = Task { () -> [LiveTranscriptSegment] in
            var values: [LiveTranscriptSegment] = []
            for await segment in fixture.pipeline.segments where segment.isFinal {
                values.append(segment)
            }
            return values
        }
        let startedAt = ContinuousClock.now

        for _ in 0..<4 {
            await fixture.pipeline.consume(try frame(samples: 16_000))
        }
        let ingestionDuration = startedAt.duration(to: .now)
        let ingestionSeconds = Double(ingestionDuration.components.seconds)
            + Double(ingestionDuration.components.attoseconds) / 1e18
        await fixture.pipeline.finish()
        let finalized = await collector.value

        XCTAssertLessThan(ingestionSeconds, 0.5)
        XCTAssertEqual(finalized.count, 2)
        XCTAssertEqual(finalized.map(\.start), [0, 2])
        XCTAssertEqual(finalized.map(\.end), [2, 4])
    }

    private func frame(samples: Int) throws -> CapturedAudioFrame {
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))
        )
        buffer.frameLength = AVAudioFrameCount(samples)
        for index in 0..<samples { buffer.floatChannelData?[0][index] = 0.1 }
        return CapturedAudioFrame(
            buffer: buffer,
            capturedAt: .now,
            activity: AudioActivityMeter.measure(buffer: buffer)
        )
    }

    private func makeFixture(
        behavior: StubSpeechRecognizer.Behavior = .output("recognized lecture"),
        delay: Duration? = nil
    ) async throws -> (
        pipeline: LiveTranscriptionPipeline,
        recognizer: StubSpeechRecognizer,
        repository: SQLiteTranscriptRevisionRepository,
        session: LectureSession,
        databaseURL: URL
    ) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcription-\(UUID().uuidString).sqlite")
        let setup = try await MainActor.run { () -> (
            LectureDatabase,
            SQLiteTranscriptRevisionRepository,
            LectureSession
        ) in
            let database = try LectureDatabase(url: url)
            try database.migrate()
            let session = LectureSession(title: "Transcription")
            try SQLiteLectureSessionRepository(database: database).save(session)
            return (database, SQLiteTranscriptRevisionRepository(database: database), session)
        }
        let recognizer = StubSpeechRecognizer(behavior: behavior, delay: delay)
        let pipeline = LiveTranscriptionPipeline(
            sessionID: setup.2.id,
            recognizer: recognizer,
            repository: setup.1,
            finalWindowSeconds: 2,
            partialWindowSeconds: 1
        )
        _ = setup.0
        return (pipeline, recognizer, setup.1, setup.2, url)
    }
}
