import Foundation
import XCTest
@testable import LectureAssistant

@MainActor
final class DerivedHistoryTests: XCTestCase {
    func testCorrectionMarksTranslationsAndNotesStaleWhileKeepingHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("derived-history-\(UUID().uuidString).sqlite")
        let database = try LectureDatabase(url: url)
        try database.migrate()
        let session = LectureSession(title: "History")
        try SQLiteLectureSessionRepository(database: database).save(session)
        let revisions = SQLiteTranscriptRevisionRepository(database: database)
        let first = try revisions.createRevision(sessionID: session.id, segmentID: "segment-0", startsAt: 0, endsAt: 1, text: "old", status: .finalized)
        let translation = try SQLiteTranslationRepository(database: database).save(sessionID: session.id, sourceRevisionID: first.id, languageCode: "zh-Hans", text: "旧", providerID: "provider", model: "model")
        let note = try SQLiteNoteVersionRepository(database: database).save(sessionID: session.id, contentJSON: "{}", providerID: "provider", model: "model", evidenceRevisionIDs: [first.id])

        _ = try revisions.createRevision(sessionID: session.id, segmentID: "segment-0", startsAt: 0, endsAt: 1, text: "corrected", status: .confirmed)

        let translationHistory = try SQLiteTranslationRepository(database: database).history(sessionID: session.id, sourceRevisionID: first.id)
        let noteHistory = try SQLiteNoteVersionRepository(database: database).all(sessionID: session.id)
        XCTAssertEqual(translationHistory.first?.id, translation.id)
        XCTAssertEqual(translationHistory.first?.state, .stale)
        XCTAssertEqual(noteHistory.first?.id, note.id)
        XCTAssertEqual(noteHistory.first?.state, .stale)
    }
}
