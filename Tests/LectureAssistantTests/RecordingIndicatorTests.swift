import Foundation
import XCTest
@testable import LectureAssistant

final class RecordingIndicatorTests: XCTestCase {
    @MainActor
    func testIndicatorPersistsRecordingPauseAndCompletionStates() throws {
        let defaultsName = #function
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let sessionID = SessionID()
        let store = RecordingIndicatorStore(defaults: defaults)

        store.begin(sessionID: sessionID, at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(store.snapshot.state, .recording)
        XCTAssertTrue(store.snapshot.state.isMicrophoneOwned)
        XCTAssertEqual(store.snapshot.sessionID, sessionID)

        store.pause(at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(store.snapshot.state, .paused)
        store.resume(at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(store.snapshot.state, .recording)
        store.stopping(at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(store.snapshot.state, .stopping)
        store.completed(at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(store.snapshot.state, .completed)

        let restored = RecordingIndicatorStore(defaults: defaults)
        XCTAssertEqual(restored.snapshot, store.snapshot)
        XCTAssertFalse(restored.snapshot.state.isMicrophoneOwned)
    }

    @MainActor
    func testRestartConvertsOwnedMicrophoneStateToInterrupted() {
        let defaultsName = #function
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let sessionID = SessionID()
        let first = RecordingIndicatorStore(defaults: defaults)
        first.begin(sessionID: sessionID)
        first.pause()

        let restarted = RecordingIndicatorStore(defaults: defaults)

        XCTAssertEqual(restarted.snapshot.state, .interrupted)
        XCTAssertEqual(restarted.snapshot.sessionID, sessionID)
        XCTAssertFalse(restarted.snapshot.state.isMicrophoneOwned)
    }

    @MainActor
    func testInvalidIndicatorTransitionsAreIgnored() {
        let defaultsName = #function
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let store = RecordingIndicatorStore(defaults: defaults)

        store.pause()
        store.resume()
        store.stopping()
        XCTAssertEqual(store.snapshot.state, .hidden)

        store.begin(sessionID: SessionID())
        store.pause()
        store.pause()
        XCTAssertEqual(store.snapshot.state, .paused)
    }
}
