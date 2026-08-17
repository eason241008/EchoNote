import Foundation
import SQLite3
import XCTest
@testable import LectureAssistant

private actor StubTranslationProvider: SimplifiedChineseTranslationProviding {
    let providerID = "stub"
    let model = "translation-model"
    private var error: Error?
    private(set) var requests: [SimplifiedChineseTranslationRequest] = []

    private let delay: Duration?

    init(error: Error? = nil, delay: Duration? = nil) {
        self.error = error
        self.delay = delay
    }

    func translate(
        _ request: SimplifiedChineseTranslationRequest
    ) async throws -> SimplifiedChineseTranslationResponse {
        requests.append(request)
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        return try SimplifiedChineseTranslationResponse(
            translations: request.segments.map {
                try SimplifiedChineseTranslation(revisionID: $0.revisionID, text: "中文：\($0.text)")
            },
            matching: request
        )
    }

    func clearError() { error = nil }
    func requestCount() -> Int { requests.count }
    func latestRequest() -> SimplifiedChineseTranslationRequest? { requests.last }
    func allRequests() -> [SimplifiedChineseTranslationRequest] { requests }
}

final class TranslationPipelineTests: XCTestCase {
    func testBacklogIsSplitIntoSmallProviderBatches() async throws {
        let provider = StubTranslationProvider()
        let pipeline = TranslationPipeline(
            provider: provider,
            batchingDelay: .milliseconds(10),
            maximumBatchSize: 8
        )

        for index in 0..<20 {
            await pipeline.enqueue(.init(
                sessionID: SessionID(),
                revisionID: TranscriptRevisionID(),
                text: "Sentence \(index)"
            ))
        }
        try await Task.sleep(for: .milliseconds(100))
        await pipeline.finish()

        let requests = await provider.allRequests()
        XCTAssertEqual(requests.flatMap(\.segments).count, 20)
        XCTAssertTrue(requests.allSatisfy { $0.segments.count <= 8 })
    }

    func testContractsEncodeTextAndRevisionIDsWithoutAudioOrPaths() throws {
        let segment = try TranslationSourceSegment(
            revisionID: TranscriptRevisionID(),
            text: "Dynamic programming"
        )
        let request = try SimplifiedChineseTranslationRequest(segments: [segment])
        let json = String(data: try JSONEncoder().encode(request), encoding: .utf8)!

        XCTAssertTrue(json.contains("Dynamic programming"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("audio"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("path"))
        XCTAssertFalse(json.contains("file://"))
    }

    func testAdjacentFinalizedRevisionsAreMicrobatchedAndPersistedWithExactLinks() async throws {
        let fixture = try await makeFixture()
        let provider = StubTranslationProvider()
        let pipeline = TranslationPipeline(
            provider: provider,
            repository: fixture.repository,
            batchingDelay: .milliseconds(20)
        )
        let sourceRevisions = try await MainActor.run {
            try [
                fixture.revisions.createRevision(
                    sessionID: fixture.session.id,
                    segmentID: "segment-0",
                    startsAt: 0,
                    endsAt: 1,
                    text: "First",
                    status: .finalized
                ),
                fixture.revisions.createRevision(
                    sessionID: fixture.session.id,
                    segmentID: "segment-1",
                    startsAt: 1,
                    endsAt: 2,
                    text: "Second",
                    status: .finalized
                ),
            ]
        }
        let first = sourceRevisions[0].id
        let second = sourceRevisions[1].id
        let collector = Task { () -> [TranslationPipelineState] in
            var values: [TranslationPipelineState] = []
            for await state in pipeline.states { values.append(state) }
            return values
        }

        await pipeline.enqueue(.init(sessionID: fixture.session.id, revisionID: first, text: "First"))
        await pipeline.enqueue(.init(sessionID: fixture.session.id, revisionID: second, text: "Second"))
        try await Task.sleep(for: .milliseconds(80))
        await pipeline.finish()
        let states = await collector.value

        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 1)
        let request = await provider.latestRequest()
        XCTAssertEqual(request?.segments.map(\.revisionID), [first, second])
        XCTAssertTrue(states.contains { $0 == .translated([first, second]) })
        let links = try await MainActor.run {
            try fixture.database.query(
                "SELECT source_revision_id FROM translations ORDER BY created_at",
                bindings: []
            ) { statement in String(cString: sqlite3_column_text(statement, 0)) }
        }
        XCTAssertEqual(Set(links), Set([first.rawValue.uuidString, second.rawValue.uuidString]))
    }

    func testFinishWaitsForInFlightTranslationBeforeClosingResults() async throws {
        let provider = StubTranslationProvider(delay: .milliseconds(80))
        let pipeline = TranslationPipeline(provider: provider, batchingDelay: .milliseconds(5))
        let revisionID = TranscriptRevisionID()
        let resultTask = Task { () -> SimplifiedChineseTranslation? in
            for await result in pipeline.results { return result }
            return nil
        }

        await pipeline.enqueue(.init(
            sessionID: SessionID(),
            revisionID: revisionID,
            text: "Final lecture sentence"
        ))
        try await Task.sleep(for: .milliseconds(20))
        await pipeline.finish()
        let result = await resultTask.value

        XCTAssertEqual(result?.revisionID, revisionID)
        XCTAssertEqual(result?.text, "中文：Final lecture sentence")
    }

    func testRetryableFailureKeepsBatchForRetry() async throws {
        let provider = StubTranslationProvider(error: TranslationProviderError.timedOut)
        let pipeline = TranslationPipeline(provider: provider, batchingDelay: .milliseconds(10))
        let revisionID = TranscriptRevisionID()
        let collector = Task { () -> [TranslationPipelineState] in
            var values: [TranslationPipelineState] = []
            for await state in pipeline.states { values.append(state) }
            return values
        }

        await pipeline.enqueue(.init(sessionID: SessionID(), revisionID: revisionID, text: "Retry"))
        try await Task.sleep(for: .milliseconds(40))
        await provider.clearError()
        await pipeline.retry()
        await pipeline.finish()
        let states = await collector.value

        XCTAssertTrue(states.contains { $0 == .failed(retryable: true, message: TranslationProviderError.timedOut.localizedDescription) })
        XCTAssertTrue(states.contains { $0 == .translated([revisionID]) })
    }

    func testMissingProviderStaysEnglishOnly() async {
        let pipeline = TranslationPipeline(provider: nil)
        let collector = Task { () -> [TranslationPipelineState] in
            var values: [TranslationPipelineState] = []
            for await state in pipeline.states { values.append(state) }
            return values
        }
        await pipeline.enqueue(.init(sessionID: SessionID(), revisionID: TranscriptRevisionID(), text: "English"))
        await pipeline.finish()
        let states = await collector.value
        XCTAssertFalse(states.isEmpty)
        XCTAssertTrue(states.allSatisfy { $0 == .englishOnly })
    }

    @MainActor
    private func makeFixture() throws -> (
        database: LectureDatabase,
        repository: SQLiteTranslationRepository,
        revisions: SQLiteTranscriptRevisionRepository,
        session: LectureSession
    ) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-pipeline-\(UUID().uuidString).sqlite")
        let database = try LectureDatabase(url: url)
        try database.migrate()
        let session = LectureSession(title: "Translation")
        try SQLiteLectureSessionRepository(database: database).save(session)
        return (
            database,
            SQLiteTranslationRepository(database: database),
            SQLiteTranscriptRevisionRepository(database: database),
            session
        )
    }
}
