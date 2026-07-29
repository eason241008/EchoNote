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
        let revisionID = TranscriptRevisionID()
        model.append(LiveTranscriptSegment(
            id: "segment-1",
            sessionID: SessionID(),
            start: 1,
            end: 4,
            text: "A longer English caption should begin at the left padding and wrap naturally.",
            isFinal: true,
            revisionID: revisionID
        ))
        model.setTranslationAvailable(true)
        model.setTranslation("较长的中文字幕应从左侧内边距开始，并自然换行。", for: revisionID)
        let controller = CaptionOverlayWindowController(model: model)

        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.windowLevel, .floating)
        XCTAssertEqual(controller.windowSize, NSSize(width: 960, height: 260))
        if let snapshotPath = ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_OVERLAY_SNAPSHOT"] {
            let data = try XCTUnwrap(controller.snapshotPNG())
            try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        if ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_OVERLAY_HOLD"] == "1" {
            RunLoop.main.run(until: Date().addingTimeInterval(5))
        }
        controller.hide()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(
            model.segments.map(\.text),
            [
                "Visible caption",
                "A longer English caption should begin at the left padding and wrap naturally.",
            ]
        )
        XCTAssertTrue(model.settings.isHidden)
    }
}
