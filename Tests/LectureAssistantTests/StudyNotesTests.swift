import Foundation
import XCTest
@testable import LectureAssistant

private struct StubNoteProvider: StudyNoteGenerating {
    let providerID = "notes"
    let model = "notes-model"
    let note: StructuredStudyNote
    func generate(_ request: TextOnlyStudyNoteRequest) async throws -> StructuredStudyNote { note }
}
@MainActor
final class StudyNotesTests: XCTestCase {
    func testBookmarkPersistsTimestampAndKind() throws {
        let fixture = try makeFixture()
        let bookmark = LectureBookmark(sessionID: fixture.session.id, kind: .question, sessionTime: 42.5, text: "Clarify proof")
        let repository = SQLiteBookmarkRepository(database: fixture.database)
        let saved = try repository.save(bookmark)
        XCTAssertEqual(saved, bookmark)
        let values = try repository.all(sessionID: fixture.session.id)
        XCTAssertEqual(values, [bookmark])
    }

    func testUnsupportedGeneratedEvidenceIsRejected() async throws {
        let unknown = TranscriptRevisionID()
        let provider = StubNoteProvider(note: StructuredStudyNote(summary: ["Claim"], keyConcepts: [], terminology: [], actionItems: [], bookmarkedQuestions: [], evidence: [NoteEvidence(revisionID: unknown, start: 0, end: 1)]))
        let request = TextOnlyStudyNoteRequest(transcript: [], bookmarks: [], terminology: [])
        let generator = ValidatingStudyNoteGenerator(provider: provider)
        do {
            _ = try await generator.generate(request, availableRevisionIDs: [])
            XCTFail("Expected unsupported evidence rejection")
        } catch let error as StudyNoteValidationError {
            XCTAssertEqual(error, .unknownRevision(unknown))
        }
    }

    func testStructuredNoteRequiresEvidence() async throws {
        let provider = StubNoteProvider(note: StructuredStudyNote(summary: ["Claim"], keyConcepts: [], terminology: [], actionItems: [], bookmarkedQuestions: [], evidence: []))
        let generator = ValidatingStudyNoteGenerator(provider: provider)
        do {
            _ = try await generator.generate(TextOnlyStudyNoteRequest(transcript: [], bookmarks: [], terminology: []), availableRevisionIDs: [])
            XCTFail("Expected missing evidence rejection")
        } catch let error as StudyNoteValidationError {
            XCTAssertEqual(error, .noEvidence)
        }
    }

    func testPostLecturePipelinePersistsStructuredNoteWithEvidence() async throws {
        let fixture = try makeFixture()
        let revision = try SQLiteTranscriptRevisionRepository(database: fixture.database)
            .createRevision(
                sessionID: fixture.session.id,
                segmentID: "segment-0",
                startsAt: 0,
                endsAt: 2,
                text: "Dynamic programming",
                status: .finalized
            )
        let note = StructuredStudyNote(
            summary: ["Dynamic programming reuses subproblems."],
            keyConcepts: ["memoization"],
            terminology: ["optimal substructure"],
            actionItems: [],
            bookmarkedQuestions: [],
            evidence: [NoteEvidence(revisionID: revision.id, start: 0, end: 2)]
        )
        let pipeline = StudyNotePipeline(
            generator: ValidatingStudyNoteGenerator(provider: StubNoteProvider(note: note)),
            repository: SQLiteNoteVersionRepository(database: fixture.database)
        )
        let request = TextOnlyStudyNoteRequest(
            transcript: [
                try TranslationSourceSegment(
                    revisionID: revision.id,
                    text: revision.text
                )
            ],
            bookmarks: [],
            terminology: []
        )

        let stored = try await pipeline.generateAndPersist(
            sessionID: fixture.session.id,
            request: request
        )

        XCTAssertEqual(stored.versionNumber, 1)
        XCTAssertTrue(stored.contentJSON.contains("memoization"))
        XCTAssertEqual(
            try SQLiteNoteVersionRepository(database: fixture.database)
                .all(sessionID: fixture.session.id)
                .first?.id,
            stored.id
        )
    }

    @MainActor
    private func makeFixture() throws -> (database: LectureDatabase, session: LectureSession) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).sqlite")
        let database = try LectureDatabase(url: url)
        try database.migrate()
        let session = LectureSession(title: "Notes")
        try SQLiteLectureSessionRepository(database: database).save(session)
        return (database, session)
    }

}
