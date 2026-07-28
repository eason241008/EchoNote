import Foundation
import XCTest
@testable import LectureAssistant

final class RevisionRepositoriesTests: XCTestCase {
    @MainActor
    func testCorrectionCreatesRevisionHistoryAndStalesExactDependents() throws {
        try withDatabase { database in
            let session = LectureSession(title: "Revision lecture")
            try SQLiteLectureSessionRepository(database: database).save(session)
            let revisions = SQLiteTranscriptRevisionRepository(database: database)
            let translations = SQLiteTranslationRepository(database: database)
            let notes = SQLiteNoteVersionRepository(database: database)

            let original = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment-a",
                startsAt: 1,
                endsAt: 3,
                text: "original text",
                status: .finalized
            )
            let unrelated = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment-b",
                startsAt: 4,
                endsAt: 6,
                text: "unrelated text",
                status: .finalized
            )
            let affectedTranslation = try translations.save(
                sessionID: session.id,
                sourceRevisionID: original.id,
                languageCode: "zh-Hans",
                text: "原文",
                providerID: "openai",
                model: "translation-model"
            )
            let unaffectedTranslation = try translations.save(
                sessionID: session.id,
                sourceRevisionID: unrelated.id,
                languageCode: "zh-Hans",
                text: "无关",
                providerID: "openai",
                model: "translation-model"
            )
            let affectedNote = try notes.save(
                sessionID: session.id,
                contentJSON: "{\"summary\":\"original\"}",
                providerID: "openai",
                model: "notes-model",
                evidenceRevisionIDs: [original.id]
            )
            let unaffectedNote = try notes.save(
                sessionID: session.id,
                contentJSON: "{\"summary\":\"unrelated\"}",
                providerID: "openai",
                model: "notes-model",
                evidenceRevisionIDs: [unrelated.id]
            )

            let correction = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment-a",
                startsAt: 1,
                endsAt: 3,
                text: "corrected text",
                status: .confirmed
            )

            XCTAssertEqual(correction.supersedes, original.id)
            XCTAssertEqual(
                try revisions.history(sessionID: session.id, segmentID: "segment-a").map(\.id),
                [original.id, correction.id]
            )
            XCTAssertEqual(
                try revisions.currentRevision(sessionID: session.id, segmentID: "segment-a")?.id,
                correction.id
            )
            XCTAssertEqual(try translations.state(id: affectedTranslation.id), .stale)
            XCTAssertEqual(try translations.state(id: unaffectedTranslation.id), .current)
            XCTAssertEqual(try notes.state(id: affectedNote.id), .stale)
            XCTAssertEqual(try notes.state(id: unaffectedNote.id), .current)
        }
    }

    @MainActor
    func testNewDerivedVersionsCanReferenceCorrectedRevisionWithoutDeletingHistory() throws {
        try withDatabase { database in
            let session = LectureSession(title: "Regeneration lecture")
            try SQLiteLectureSessionRepository(database: database).save(session)
            let revisions = SQLiteTranscriptRevisionRepository(database: database)
            let translations = SQLiteTranslationRepository(database: database)
            let notes = SQLiteNoteVersionRepository(database: database)

            _ = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment",
                startsAt: 0,
                endsAt: 2,
                text: "first",
                status: .finalized
            )
            let corrected = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment",
                startsAt: 0,
                endsAt: 2,
                text: "second",
                status: .confirmed
            )
            let regeneratedTranslation = try translations.save(
                sessionID: session.id,
                sourceRevisionID: corrected.id,
                languageCode: "zh-Hans",
                text: "第二版",
                providerID: "openai",
                model: "translation-model"
            )
            let regeneratedNote = try notes.save(
                sessionID: session.id,
                contentJSON: "{\"summary\":\"second\"}",
                providerID: "openai",
                model: "notes-model",
                evidenceRevisionIDs: [corrected.id]
            )

            XCTAssertEqual(try translations.state(id: regeneratedTranslation.id), .current)
            XCTAssertEqual(try notes.state(id: regeneratedNote.id), .current)
            XCTAssertEqual(
                try revisions.history(sessionID: session.id, segmentID: "segment").count,
                2
            )
        }
    }

    @MainActor
    private func withDatabase(_ operation: (LectureDatabase) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-revisions-\(UUID().uuidString).sqlite")
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
