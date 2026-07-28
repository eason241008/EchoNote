import Foundation
import XCTest
@testable import LectureAssistant

private final class FailOnceArtifactRemover: SessionArtifactRemoving, @unchecked Sendable {
    private var exists = true
    private var shouldFail = true
    func fileExists(atPath path: String) -> Bool { exists }
    func removeItem(at URL: URL) throws {
        if shouldFail {
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
        exists = false
    }
}

@MainActor
final class LibraryAndExportTests: XCTestCase {
    func testRetentionProtectsActiveAndDeletesAfterWindow() {
        let evaluator = RawAudioRetentionEvaluator()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        XCTAssertFalse(evaluator.decision(for: nil, now: now, policy: .days(30)).eligible)
        XCTAssertFalse(evaluator.decision(for: Date(timeIntervalSince1970: 75 * 86_400), now: now, policy: .days(30)).eligible)
        XCTAssertTrue(evaluator.decision(for: Date(timeIntervalSince1970: 60 * 86_400), now: now, policy: .days(30)).eligible)
        XCTAssertTrue(evaluator.decision(for: Date(), now: now, policy: .immediate).eligible)
    }

    func testSessionDeletionIsIdempotentAndRemovesDatabaseRow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delete-\(UUID().uuidString)")
        let database = try LectureDatabase(url: root.appendingPathExtension("sqlite"))
        try database.migrate()
        let session = LectureSession(title: "Delete")
        try SQLiteLectureSessionRepository(database: database).save(session)
        let directory = root.appendingPathComponent(session.id.rawValue.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = SessionDeletionCoordinator(database: database, sessionRoot: root)
        XCTAssertTrue(try coordinator.delete(sessionID: session.id).deletedSession)
        XCTAssertTrue(try coordinator.delete(sessionID: session.id).deletedSession)
        XCTAssertNil(try SQLiteLectureSessionRepository(database: database).session(id: session.id))
    }

    func testPartialDeletionKeepsDatabaseRowAndRetryCompletes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-delete-\(UUID().uuidString)")
        let database = try LectureDatabase(url: root.appendingPathExtension("sqlite"))
        try database.migrate()
        let session = LectureSession(title: "Retry deletion")
        try SQLiteLectureSessionRepository(database: database).save(session)
        let remover = FailOnceArtifactRemover()
        let coordinator = SessionDeletionCoordinator(
            database: database,
            sessionRoot: root,
            fileManager: remover
        )

        let partial = try coordinator.delete(sessionID: session.id)
        XCTAssertFalse(partial.deletedSession)
        XCTAssertTrue(partial.retryable)
        XCTAssertEqual(partial.remainingPaths.count, 1)
        XCTAssertNotNil(
            try SQLiteLectureSessionRepository(database: database)
                .session(id: session.id)
        )

        let completed = try coordinator.delete(sessionID: session.id)
        XCTAssertTrue(completed.deletedSession)
        XCTAssertNil(
            try SQLiteLectureSessionRepository(database: database)
                .session(id: session.id)
        )
    }

    func testSnapshotExportsGapAndExcludesSecretsAndAudioPaths() throws {
        let sessionID = SessionID()
        let snapshot = LectureSnapshot(
            sessionID: sessionID,
            title: "算法 Algorithms",
            segments: [
                .init(id: "segment-1", start: 1, end: 3, text: "Unicode 术语", isGap: false),
                .init(id: "gap-0", start: 0, end: 2, text: "Audio unavailable", isGap: true),
            ],
            translations: [],
            bookmarks: []
        )
        let exporter = LectureSnapshotExporter()
        let markdown = exporter.markdown(snapshot)
        let srt = exporter.srt(snapshot)
        let json = String(data: try exporter.json(snapshot), encoding: .utf8)!
        let pdf = exporter.pdf(snapshot)
        XCTAssertTrue(markdown.contains("[Missing transcript]"))
        XCTAssertTrue(srt.contains("[Missing transcript]"))
        XCTAssertTrue(markdown.contains("算法"))
        XCTAssertTrue(json.contains("Unicode 术语"))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:01,000"))
        XCTAssertFalse(markdown.contains("/tmp"))
        XCTAssertFalse(json.contains("apiKey"))
        XCTAssertFalse(json.contains("audio_chunks"))
    }
}
