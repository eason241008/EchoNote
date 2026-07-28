import Foundation
import XCTest
@testable import LectureAssistant

final class CaptureTimelineTests: XCTestCase {
    @MainActor
    func testAllCaptureFailureEventsPersistInSequence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-timeline-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let database = try LectureDatabase(url: url)
        try database.migrate()
        let session = LectureSession(title: "Failure timeline")
        try SQLiteLectureSessionRepository(database: database).save(session)
        let recorder = CaptureTimelineRecorder(database: database, sessionID: session.id)
        let events: [CaptureTimelineEvent] = [
            .paused, .resumed, .deviceLost, .permissionRevoked,
            .systemSleep, .audioEngineFailure, .storageFailure, .stopped,
        ]

        for (index, event) in events.enumerated() {
            _ = try recorder.record(
                event,
                details: ["source": "test"],
                at: Date(timeIntervalSince1970: Double(index))
            )
        }

        let stored = try SQLiteTimelineRepository(database: database).events(sessionID: session.id)
        XCTAssertEqual(stored.map(\.kind), events.map(\.rawValue))
        XCTAssertEqual(stored.map(\.sequenceNumber), Array(0..<Int64(events.count)))
        XCTAssertTrue(stored.allSatisfy { $0.detailsJSON == "{\"source\":\"test\"}" })
    }
}
