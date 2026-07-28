import Foundation
import XCTest
@testable import LectureAssistant

final class LectureSearchTests: XCTestCase {
    @MainActor
    func testCurrentTranscriptRevisionReplacesSupersededSearchText() throws {
        try withDatabase { database in
            let session = LectureSession(title: "Search lecture")
            try SQLiteLectureSessionRepository(database: database).save(session)
            let revisions = SQLiteTranscriptRevisionRepository(database: database)
            let search = SQLiteLectureSearchRepository(database: database)

            let original = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment-a",
                startsAt: 10,
                endsAt: 13,
                text: "gradient descent converges",
                status: .finalized
            )
            try search.indexCurrentTranscript(sessionID: session.id, segmentID: "segment-a")
            XCTAssertEqual(try search.search("gradient").first?.sourceRevisionID, original.id)

            let correction = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment-a",
                startsAt: 10,
                endsAt: 13,
                text: "stochastic optimization converges",
                status: .confirmed
            )
            try search.indexCurrentTranscript(sessionID: session.id, segmentID: "segment-a")

            XCTAssertEqual(try search.search("gradient"), [])
            let result = try XCTUnwrap(search.search("stochastic").first)
            XCTAssertEqual(result.sessionID, session.id)
            XCTAssertEqual(result.contentType, .transcript)
            XCTAssertEqual(result.contentID, "segment-a")
            XCTAssertEqual(result.sourceRevisionID, correction.id)
            XCTAssertEqual(result.startsAt, 10)
            XCTAssertEqual(result.endsAt, 13)
        }
    }

    @MainActor
    func testSearchReturnsCurrentTranslationAndNoteLocations() throws {
        try withDatabase { database in
            let session = LectureSession(title: "Derived search lecture")
            try SQLiteLectureSessionRepository(database: database).save(session)
            let revisions = SQLiteTranscriptRevisionRepository(database: database)
            let translations = SQLiteTranslationRepository(database: database)
            let notes = SQLiteNoteVersionRepository(database: database)
            let search = SQLiteLectureSearchRepository(database: database)
            let revision = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment",
                startsAt: 20,
                endsAt: 24,
                text: "neural network",
                status: .finalized
            )
            let translation = try translations.save(
                sessionID: session.id,
                sourceRevisionID: revision.id,
                languageCode: "zh-Hans",
                text: "神经网络 architecture",
                providerID: "openai",
                model: "translation-model"
            )
            let note = try notes.save(
                sessionID: session.id,
                contentJSON: "{\"summary\":\"architecture summary\"}",
                providerID: "openai",
                model: "notes-model",
                evidenceRevisionIDs: [revision.id]
            )
            try search.indexTranslation(id: translation.id)
            try search.indexNoteVersion(id: note.id)

            let results = try search.search("architecture")
            XCTAssertEqual(Set(results.map(\.contentType)), [.translation, .note])
            let translationResult = try XCTUnwrap(results.first { $0.contentType == .translation })
            XCTAssertEqual(translationResult.sourceRevisionID, revision.id)
            XCTAssertEqual(translationResult.startsAt, 20)
            XCTAssertEqual(translationResult.endsAt, 24)
            XCTAssertEqual(results.first { $0.contentType == .note }?.sessionID, session.id)
        }
    }

    @MainActor
    func testCorrectionRemovesStaleDerivedSearchDocuments() throws {
        try withDatabase { database in
            let session = LectureSession(title: "Stale search lecture")
            try SQLiteLectureSessionRepository(database: database).save(session)
            let revisions = SQLiteTranscriptRevisionRepository(database: database)
            let translations = SQLiteTranslationRepository(database: database)
            let notes = SQLiteNoteVersionRepository(database: database)
            let search = SQLiteLectureSearchRepository(database: database)
            let original = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment",
                startsAt: 0,
                endsAt: 2,
                text: "source",
                status: .finalized
            )
            let translation = try translations.save(
                sessionID: session.id,
                sourceRevisionID: original.id,
                languageCode: "zh-Hans",
                text: "obsoletekeyword",
                providerID: "openai",
                model: "translation-model"
            )
            let note = try notes.save(
                sessionID: session.id,
                contentJSON: "{\"summary\":\"obsoletekeyword\"}",
                providerID: "openai",
                model: "notes-model",
                evidenceRevisionIDs: [original.id]
            )
            try search.indexTranslation(id: translation.id)
            try search.indexNoteVersion(id: note.id)
            XCTAssertEqual(try search.search("obsoletekeyword").count, 2)

            _ = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment",
                startsAt: 0,
                endsAt: 2,
                text: "corrected source",
                status: .confirmed
            )

            XCTAssertEqual(try search.search("obsoletekeyword"), [])
        }
    }

    @MainActor
    private func withDatabase(_ operation: (LectureDatabase) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-search-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let database = try LectureDatabase(url: url)
        try database.migrate()
        try operation(database)
    }
}
