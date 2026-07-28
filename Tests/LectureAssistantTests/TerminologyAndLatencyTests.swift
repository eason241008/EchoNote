import Foundation
import XCTest
@testable import LectureAssistant

final class TerminologyAndLatencyTests: XCTestCase {
    @MainActor
    func testTerminologyIsCourseScopedAndPromptUsesEnabledTermsOnly() throws {
        try withDatabase { database in
            let courses = SQLiteCourseRepository(database: database)
            let first = Course(code: "COMP90054", title: "AI Planning")
            let second = Course(code: "COMP90024", title: "Cluster Computing")
            try courses.save(first)
            try courses.save(second)
            let terminology = SQLiteTerminologyRepository(database: database)
            try terminology.save(CourseTerminology(courseID: first.id, term: "A-star", replacement: "A*"))
            try terminology.save(CourseTerminology(courseID: first.id, term: "heuristic", enabled: false))
            try terminology.save(CourseTerminology(courseID: second.id, term: "Kubernetes"))

            XCTAssertEqual(try terminology.prompt(courseID: first.id), "A-star (preferred: A*)")
            XCTAssertEqual(try terminology.prompt(courseID: second.id), "Kubernetes")
        }
    }

    @MainActor
    func testTerminologyChangeDoesNotRewriteConfirmedRevision() throws {
        try withDatabase { database in
            let course = Course(code: "COMP90054", title: "AI Planning")
            try SQLiteCourseRepository(database: database).save(course)
            let session = LectureSession(courseID: course.id, title: "Terminology")
            try SQLiteLectureSessionRepository(database: database).save(session)
            let revisions = SQLiteTranscriptRevisionRepository(database: database)
            let confirmed = try revisions.createRevision(
                sessionID: session.id,
                segmentID: "segment-0",
                startsAt: 0,
                endsAt: 1,
                text: "A star search",
                status: .confirmed
            )
            let terminology = SQLiteTerminologyRepository(database: database)
            try terminology.save(CourseTerminology(courseID: course.id, term: "A-star", replacement: "A*"))

            let history = try revisions.history(sessionID: session.id, segmentID: "segment-0")
            XCTAssertEqual(history.count, 1)
            XCTAssertEqual(history[0].id, confirmed.id)
            XCTAssertEqual(history[0].text, confirmed.text)
        }
    }

    func testLatencyDegradesOnlyWhenRollingMedianExceedsFiveSeconds() async {
        let tracker = CaptionLatencyTracker(thresholdSeconds: 5, windowSize: 3)
        let start = ContinuousClock.now
        _ = await tracker.record(windowCompletedAt: start, publishedAt: start.advanced(by: .seconds(2)))
        _ = await tracker.record(windowCompletedAt: start, publishedAt: start.advanced(by: .seconds(6)))
        let healthy = await tracker.record(windowCompletedAt: start, publishedAt: start.advanced(by: .seconds(4)))
        XCTAssertEqual(healthy.medianSeconds, 4, accuracy: 0.001)
        XCTAssertFalse(healthy.isDegraded)

        let degraded = await tracker.record(windowCompletedAt: start, publishedAt: start.advanced(by: .seconds(7)))
        XCTAssertEqual(degraded.medianSeconds, 6, accuracy: 0.001)
        XCTAssertTrue(degraded.isDegraded)
    }

    @MainActor
    private func withDatabase(_ operation: (LectureDatabase) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminology-\(UUID().uuidString).sqlite")
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
