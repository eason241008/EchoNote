import Foundation
import SQLite3
import XCTest
@testable import LectureAssistant

final class LectureDatabaseMigrationTests: XCTestCase {
    @MainActor
    func testMigratesExistingVersionOneDatabaseToVersionTwoWithoutDataLoss() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-migration-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let database = try LectureDatabase(url: url)
        try database.execute("BEGIN IMMEDIATE")
        for statement in LectureDatabaseSchema.migrations[0].statements {
            try database.execute(statement)
        }
        try database.execute("PRAGMA user_version = 1")
        try database.execute("COMMIT")

        let course = Course(code: "COMP90054", title: "AI Planning")
        try SQLiteCourseRepository(database: database).save(course)
        XCTAssertEqual(try database.userVersion(), 1)
        XCTAssertFalse(try database.tableNames().contains("lecture_search"))

        try database.migrate()

        XCTAssertEqual(try database.userVersion(), 3)
        XCTAssertEqual(try SQLiteCourseRepository(database: database).all(), [course])
        XCTAssertTrue(try database.tableNames().contains("lecture_search"))
        XCTAssertEqual(try SQLiteLectureSearchRepository(database: database).search("planning"), [])
    }
}
