import XCTest
@testable import LectureAssistant

private struct LegacyLectureSession: Codable {
    let id: SessionID
    let courseID: CourseID?
    let title: String
    let state: SessionState
    let createdAt: LectureTimestamp
    let updatedAt: LectureTimestamp
}

final class ApplicationModelTests: XCTestCase {
    @MainActor
    func testPreparedSessionRequiresExplicitStart() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = ApplicationModel(defaults: defaults)

        model.prepareSession(title: "Algorithms")

        XCTAssertEqual(model.activeSession?.state, .prepared)
        XCTAssertEqual(model.activeSession?.title, "Algorithms")
    }

    @MainActor
    func testRestoresInterruptedRecordingAsInterrupted() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let session = LectureSession(title: "Networks", state: .recording)
        defaults.set(try JSONEncoder().encode(session), forKey: "lecture-assistant.active-session")

        let model = ApplicationModel(defaults: defaults)

        XCTAssertEqual(model.activeSession?.state, .interrupted)
    }

    @MainActor
    func testRestoresSessionSavedBeforeScheduleLinkFieldsExisted() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let legacy = LegacyLectureSession(
            id: SessionID(),
            courseID: nil,
            title: "Legacy lecture",
            state: .paused,
            createdAt: LectureTimestamp(),
            updatedAt: LectureTimestamp()
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: "lecture-assistant.active-session"
        )

        let model = ApplicationModel(defaults: defaults)

        XCTAssertEqual(model.activeSession?.title, "Legacy lecture")
        XCTAssertEqual(model.activeSession?.state, .interrupted)
        XCTAssertNil(model.activeSession?.scheduledEventID)
        XCTAssertNil(model.activeSession?.scheduledEndAt)
    }
}
