import Foundation
import XCTest
@testable import LectureAssistant

final class LectureRepositoriesTests: XCTestCase {
    @MainActor
    func testCourseAndSessionRepositoriesRoundTripUpdates() throws {
        try withDatabase { database in
            let courseRepository = SQLiteCourseRepository(database: database)
            let sessionRepository = SQLiteLectureSessionRepository(database: database)
            let course = Course(code: "COMP90054", title: "AI Planning")
            try courseRepository.save(course)

            var updatedCourse = course
            updatedCourse.title = "AI Planning for Autonomy"
            try courseRepository.save(updatedCourse)
            XCTAssertEqual(try courseRepository.all(), [updatedCourse])

            var session = LectureSession(courseID: course.id, title: "Week 1")
            try sessionRepository.save(session)
            session.state = .recording
            session.title = "Week 1 Introduction"
            try sessionRepository.save(session)

            let loaded = try XCTUnwrap(sessionRepository.session(id: session.id))
            XCTAssertEqual(loaded.id, session.id)
            XCTAssertEqual(loaded.courseID, session.courseID)
            XCTAssertEqual(loaded.title, session.title)
            XCTAssertEqual(loaded.state, session.state)
            XCTAssertEqual(loaded.createdAt.date.timeIntervalSince1970, session.createdAt.date.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(loaded.updatedAt.date.timeIntervalSince1970, session.updatedAt.date.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    @MainActor
    func testTimelineSequenceIsStableAndMonotonicPerSession() throws {
        try withDatabase { database in
            let sessionRepository = SQLiteLectureSessionRepository(database: database)
            let timelineRepository = SQLiteTimelineRepository(database: database)
            let firstSession = LectureSession(title: "First")
            let secondSession = LectureSession(title: "Second")
            try sessionRepository.save(firstSession)
            try sessionRepository.save(secondSession)

            let first = try timelineRepository.append(sessionID: firstSession.id, kind: "prepared")
            let second = try timelineRepository.append(sessionID: firstSession.id, kind: "recording")
            let other = try timelineRepository.append(sessionID: secondSession.id, kind: "prepared")

            XCTAssertEqual(first.sequenceNumber, 0)
            XCTAssertEqual(second.sequenceNumber, 1)
            XCTAssertEqual(other.sequenceNumber, 0)
            XCTAssertEqual(
                try timelineRepository.events(sessionID: firstSession.id).map(\.kind),
                ["prepared", "recording"]
            )
        }
    }

    @MainActor
    func testTransactionRollsBackAllWritesWhenOperationThrows() throws {
        enum ExpectedFailure: Error { case rollback }

        try withDatabase { database in
            let courseRepository = SQLiteCourseRepository(database: database)
            XCTAssertThrowsError(
                try database.transaction {
                    try courseRepository.save(Course(code: "COMP10001", title: "Foundations"))
                    throw ExpectedFailure.rollback
                }
            )
            XCTAssertEqual(try courseRepository.all(), [])
        }
    }

    @MainActor
    private func withDatabase(_ operation: (LectureDatabase) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-repositories-\(UUID().uuidString).sqlite")
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
