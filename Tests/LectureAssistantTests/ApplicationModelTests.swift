import XCTest
@testable import LectureAssistant

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
}
