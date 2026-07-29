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
            text: "The first finalized lecture segment remains available above the current sentence instead of being discarded when another segment begins.",
            isFinal: true
        ))
        let revisionID = TranscriptRevisionID()
        model.append(LiveTranscriptSegment(
            id: "segment-1",
            sessionID: SessionID(),
            start: 1,
            end: 4,
            text: "The second English caption is deliberately long enough to wrap across several visual lines without using an ellipsis or a fixed line limit, so every word remains readable while the lecturer continues explaining the topic in detail.",
            isFinal: true,
            revisionID: revisionID
        ))
        model.setTranslationAvailable(true)
        model.setTranslation("第二段中文字幕也应完整保留并自然换行，不得因为固定行数限制而显示省略号。", for: revisionID)
        let latestRevisionID = TranscriptRevisionID()
        model.append(LiveTranscriptSegment(
            id: "segment-2",
            sessionID: SessionID(),
            start: 4,
            end: 9,
            text: "The newest caption continues downward inside a scrollable history, automatically follows partial text growth, and keeps the complete English sentence visible even when it becomes much longer than the floating panel height.",
            isFinal: true,
            revisionID: latestRevisionID
        ))
        model.setTranslation(
            "最新的中文字幕会继续向下排列，浮动窗口自动跟随到最下方，同时历史段落仍可向上滚动查看。",
            for: latestRevisionID
        )
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
                "The first finalized lecture segment remains available above the current sentence instead of being discarded when another segment begins.",
                "The second English caption is deliberately long enough to wrap across several visual lines without using an ellipsis or a fixed line limit, so every word remains readable while the lecturer continues explaining the topic in detail.",
                "The newest caption continues downward inside a scrollable history, automatically follows partial text growth, and keeps the complete English sentence visible even when it becomes much longer than the floating panel height.",
            ]
        )
        XCTAssertTrue(model.settings.isHidden)
    }
}
