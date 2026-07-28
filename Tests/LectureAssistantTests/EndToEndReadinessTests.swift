import AVFoundation
import Foundation
import XCTest
@testable import LectureAssistant

@MainActor
final class EndToEndReadinessTests: XCTestCase {
    func testLectureDataFlowFromScheduleToExportPreservesPrivacyAndProvenance() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).sqlite")
        let database = try LectureDatabase(url: url)
        try database.migrate()
        let course = Course(code: "COMP90054", title: "Algorithms")
        try SQLiteCourseRepository(database: database).save(course)
        let occurrenceRepository = SQLiteOccurrenceRepository(database: database)
        let event = ICSCourseEvent(uid: "uid", summary: "Algorithms", startsAt: Date(), endsAt: Date().addingTimeInterval(3600), recurrenceID: "single")
        let preview = try occurrenceRepository.preview(events: [event], courseID: course.id)
        try occurrenceRepository.apply(preview, courseID: course.id)
        XCTAssertEqual(try occurrenceRepository.all(courseID: course.id).count, 1)

        let session = LectureSession(courseID: course.id, title: event.summary)
        XCTAssertEqual(session.state, .prepared)
        try SQLiteLectureSessionRepository(database: database).save(session)
        let revisions = SQLiteTranscriptRevisionRepository(database: database)
        let revision = try revisions.createRevision(sessionID: session.id, segmentID: "segment-0", startsAt: 0, endsAt: 2, text: "Dynamic programming", status: .finalized)
        let translation = try SQLiteTranslationRepository(database: database).save(sessionID: session.id, sourceRevisionID: revision.id, languageCode: "zh-Hans", text: "动态规划", providerID: "provider", model: "model")
        let bookmark = try SQLiteBookmarkRepository(database: database).save(.init(sessionID: session.id, kind: .question, sessionTime: 1, text: "Why memoize?"))
        let corrected = try revisions.createRevision(sessionID: session.id, segmentID: "segment-0", startsAt: 0, endsAt: 2, text: "Dynamic programming uses memoization", status: .confirmed)
        XCTAssertEqual(try SQLiteTranslationRepository(database: database).state(id: translation.id), .stale)
        let search = SQLiteLectureSearchRepository(database: database)
        try search.indexCurrentTranscript(sessionID: session.id, segmentID: "segment-0")
        XCTAssertEqual(try search.search("memoization").first?.sourceRevisionID, corrected.id)

        let snapshot = LectureSnapshot(sessionID: session.id, title: session.title, segments: [.init(id: "segment-0", start: 0, end: 2, text: corrected.text, isGap: false)], translations: [], bookmarks: [bookmark])
        let exporter = LectureSnapshotExporter()
        let markdown = exporter.markdown(snapshot)
        let json = String(data: try exporter.json(snapshot), encoding: .utf8)!
        XCTAssertTrue(markdown.contains("memoization"))
        XCTAssertFalse(json.contains("apiKey"))
        XCTAssertFalse(json.contains("file://"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("audioPath"))
    }
}
