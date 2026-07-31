import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

private actor StubStreamingSpeechRecognizer: StreamingSpeechRecognizing {
    enum Failure: Error { case recognition }

    private var partials: [String]
    private var finalText: String
    private var shouldFail: Bool
    private(set) var consumedBufferCount = 0
    private(set) var finalizeCount = 0
    private(set) var resetCount = 0

    init(partials: [String], finalText: String, shouldFail: Bool = false) {
        self.partials = partials
        self.finalText = finalText
        self.shouldFail = shouldFail
    }

    func consume(_ buffer: AVAudioPCMBuffer) async throws -> String {
        consumedBufferCount += 1
        if shouldFail { throw Failure.recognition }
        return partials.isEmpty ? finalText : partials.removeFirst()
    }

    func finalize() async throws -> String {
        finalizeCount += 1
        if shouldFail { throw Failure.recognition }
        return finalText
    }

    func reset() async { resetCount += 1 }

    func counts() -> (consumed: Int, finalized: Int, reset: Int) {
        (consumedBufferCount, finalizeCount, resetCount)
    }
}

final class LiveTranscriptionTests: XCTestCase {
    func testPublishesPartialThenFinalAndPersistsOnlyFinalRevision() async throws {
        let fixture = try await makeFixture(
            partials: ["recognized", "recognized lecture"],
            finalText: "recognized lecture"
        )
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -12))
        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -12))
        await fixture.pipeline.pause()
        await fixture.pipeline.finish()
        let segments = await collector.value

        XCTAssertTrue(segments.contains { !$0.isFinal && $0.text == "recognized" })
        let finalized = try XCTUnwrap(segments.last { $0.isFinal && !$0.isGap })
        XCTAssertEqual(finalized.text, "recognized lecture")
        let stored = try await MainActor.run {
            try fixture.repository.history(sessionID: fixture.session.id, segmentID: finalized.id)
        }
        XCTAssertEqual(stored.map(\.text), ["recognized lecture"])
        let counts = await fixture.recognizer.counts()
        XCTAssertEqual(counts.finalized, 1)
    }

    func testClassroomNoiseAfterSpeechFinalizesAndCreatesTranslatableRevision() async throws {
        let fixture = try await makeFixture(
            partials: ["a complete lecture sentence", "a complete lecture sentence"],
            finalText: "a complete lecture sentence"
        )
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -16))
        await fixture.pipeline.consume(try frame(seconds: 0.6, decibels: -42))
        await fixture.pipeline.consume(try frame(seconds: 0.6, decibels: -42))
        let countsBeforeStop = await fixture.recognizer.counts()
        XCTAssertEqual(countsBeforeStop.finalized, 1)
        let storedBeforeStop = try await MainActor.run {
            try fixture.repository.history(sessionID: fixture.session.id, segmentID: "segment-0")
        }
        XCTAssertEqual(storedBeforeStop.map(\.text), ["a complete lecture sentence"])

        await fixture.pipeline.finish()
        let segments = await collector.value
        let finalized = try XCTUnwrap(segments.first { $0.isFinal && !$0.isGap })
        XCTAssertNotNil(finalized.revisionID)
    }

    func testSilenceBoundaryFinalizesUtteranceAndStartsNextSegment() async throws {
        let fixture = try await makeFixture(
            partials: ["first", "first", "first", "second"],
            finalText: "first sentence"
        )
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -10))
        await fixture.pipeline.consume(try frame(seconds: 0.6, decibels: -80))
        await fixture.pipeline.consume(try frame(seconds: 0.6, decibels: -80))
        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -10))
        await fixture.pipeline.finish()
        let segments = await collector.value

        let finalized = segments.filter { $0.isFinal && !$0.isGap }
        XCTAssertEqual(finalized.count, 2)
        XCTAssertEqual(finalized.map(\.id), ["segment-0", "segment-1"])
        XCTAssertLessThan(finalized[0].end, finalized[1].end)
    }

    func testNaturalPauseFinalizesBeforeNextSentence() async throws {
        let fixture = try await makeFixture(
            partials: ["first sentence", "first sentence", "second sentence"],
            finalText: "first sentence"
        )
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 0.5, decibels: -12))
        await fixture.pipeline.consume(try frame(seconds: 0.5, decibels: -70))
        let countsBeforeNextSentence = await fixture.recognizer.counts()
        XCTAssertEqual(countsBeforeNextSentence.finalized, 1)

        await fixture.pipeline.consume(try frame(seconds: 0.5, decibels: -12))
        await fixture.pipeline.finish()
        let finalized = await collector.value.filter { $0.isFinal && !$0.isGap }
        XCTAssertEqual(finalized.count, 2)
    }

    func testLeadingSilenceDoesNotReachRecognizerOrCreateSegments() async throws {
        let fixture = try await makeFixture(partials: [], finalText: "")
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 2, decibels: -80))
        await fixture.pipeline.finish()

        let segments = await collector.value
        XCTAssertTrue(segments.isEmpty)
        let counts = await fixture.recognizer.counts()
        XCTAssertEqual(counts.consumed, 0)
        XCTAssertEqual(counts.finalized, 0)
    }

    func testFarSensitivityRecognizesQuietSpeechFilteredByStandardSensitivity() async throws {
        let standard = try await makeFixture(
            partials: ["quiet lecture"],
            finalText: "quiet lecture",
            speechActivationDecibels: MicrophoneSensitivity.standard.speechActivationDecibels
        )
        let standardCollector = collectSegments(from: standard.pipeline)
        await standard.pipeline.consume(try frame(seconds: 1.12, decibels: -44))
        await standard.pipeline.finish()
        let standardSegments = await standardCollector.value
        XCTAssertTrue(standardSegments.isEmpty)
        let standardCounts = await standard.recognizer.counts()
        XCTAssertEqual(standardCounts.consumed, 0)

        let far = try await makeFixture(
            partials: ["quiet lecture"],
            finalText: "quiet lecture",
            speechActivationDecibels: MicrophoneSensitivity.far.speechActivationDecibels
        )
        let farCollector = collectSegments(from: far.pipeline)
        await far.pipeline.consume(try frame(seconds: 1.12, decibels: -44))
        await far.pipeline.finish()
        let finalized = await farCollector.value.filter { $0.isFinal && !$0.isGap }

        XCTAssertEqual(finalized.map(\.text), ["quiet lecture"])
        let farCounts = await far.recognizer.counts()
        XCTAssertEqual(farCounts.consumed, 1)
    }

    func testPauseForcesFinalWithoutWaitingForSilence() async throws {
        let fixture = try await makeFixture(partials: ["lecture"], finalText: "lecture complete")
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 0.5, decibels: -8))
        await fixture.pipeline.pause()
        await fixture.pipeline.finish()
        let finalized = await collector.value.filter { $0.isFinal && !$0.isGap }

        XCTAssertEqual(finalized.map(\.text), ["lecture complete"])
        let counts = await fixture.recognizer.counts()
        XCTAssertEqual(counts.finalized, 1)
    }

    func testPausedPipelineIgnoresFramesUntilResume() async throws {
        let fixture = try await makeFixture(
            partials: ["before pause", "after resume"],
            finalText: "final sentence"
        )
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 0.5, decibels: -8))
        await fixture.pipeline.pause()
        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -8))
        await fixture.pipeline.resume()
        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -8))
        await fixture.pipeline.finish()
        _ = await collector.value

        let counts = await fixture.recognizer.counts()
        XCTAssertEqual(counts.consumed, 2)
        XCTAssertEqual(counts.finalized, 2)
    }

    func testRecognitionFailureCreatesExplicitGapRevision() async throws {
        let fixture = try await makeFixture(partials: [], finalText: "", shouldFail: true)
        let collector = collectSegments(from: fixture.pipeline)

        await fixture.pipeline.consume(try frame(seconds: 1.12, decibels: -10))
        await fixture.pipeline.finish()
        let segments = await collector.value
        let gap = try XCTUnwrap(segments.first { $0.isGap })

        let stored = try await MainActor.run {
            try fixture.repository.history(sessionID: fixture.session.id, segmentID: gap.id)
        }
        XCTAssertEqual(stored.count, 1)
        XCTAssertGreaterThan(stored[0].end, stored[0].start)
        let counts = await fixture.recognizer.counts()
        XCTAssertEqual(counts.reset, 1)
    }

    private func collectSegments(
        from pipeline: LiveTranscriptionPipeline
    ) -> Task<[LiveTranscriptSegment], Never> {
        Task {
            var values: [LiveTranscriptSegment] = []
            for await segment in pipeline.segments { values.append(segment) }
            return values
        }
    }

    private func frame(seconds: Double, decibels: Float) throws -> CapturedAudioFrame {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let samples = max(1, Int(seconds * 16_000))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))
        )
        buffer.frameLength = AVAudioFrameCount(samples)
        return CapturedAudioFrame(
            buffer: buffer,
            capturedAt: .now,
            activity: AudioActivityLevel(
                rootMeanSquare: decibels <= -80 ? 0 : pow(10, decibels / 20),
                decibels: decibels
            )
        )
    }

    private func makeFixture(
        partials: [String],
        finalText: String,
        shouldFail: Bool = false,
        speechActivationDecibels: Float = -38
    ) async throws -> (
        pipeline: LiveTranscriptionPipeline,
        recognizer: StubStreamingSpeechRecognizer,
        repository: SQLiteTranscriptRevisionRepository,
        session: LectureSession
    ) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-transcription-\(UUID().uuidString).sqlite")
        let setup = try await MainActor.run { () -> (
            SQLiteTranscriptRevisionRepository,
            LectureSession
        ) in
            let database = try LectureDatabase(url: url)
            try database.migrate()
            let session = LectureSession(title: "Transcription")
            try SQLiteLectureSessionRepository(database: database).save(session)
            return (SQLiteTranscriptRevisionRepository(database: database), session)
        }
        let recognizer = StubStreamingSpeechRecognizer(
            partials: partials,
            finalText: finalText,
            shouldFail: shouldFail
        )
        return (
            LiveTranscriptionPipeline(
                sessionID: setup.1.id,
                recognizer: recognizer,
                repository: setup.0,
                speechActivationDecibels: speechActivationDecibels
            ),
            recognizer,
            setup.0,
            setup.1
        )
    }
}
