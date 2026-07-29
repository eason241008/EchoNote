import AppKit
import XCTest
@testable import LectureAssistant

@MainActor
final class RealCaptionOverlayTests: XCTestCase {
    func testFloatingOverlayShowsAndQuickHidesWithoutChangingState() throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_OVERLAY"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_OVERLAY=1 to exercise the AppKit overlay.")
        }
        let model = CaptionWorkspaceModel()
        model.append(LiveTranscriptSegment(
            id: "segment-0",
            sessionID: SessionID(),
            start: 0,
            end: 1,
            text: "Visible caption",
            isFinal: true
        ))
        let controller = CaptionOverlayWindowController(model: model)

        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.windowLevel, .floating)
        XCTAssertEqual(controller.windowSize, NSSize(width: 960, height: 260))

        controller.hide()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(model.segments.map(\.text), ["Visible caption"])
        XCTAssertTrue(model.settings.isHidden)
    }
}
