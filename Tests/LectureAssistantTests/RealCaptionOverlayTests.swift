import AppKit
import XCTest
@testable import LectureAssistant

@MainActor
final class RealCaptionOverlayTests: XCTestCase {
    func testFloatingOverlayShowsAndQuickHidesWithoutChangingState() throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_OVERLAY"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_OVERLAY=1 to exercise the AppKit overlay.")
        }
        let suiteName = "real-caption-overlay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = CaptionWorkspaceModel(defaults: defaults)
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
        XCTAssertEqual(controller.windowSize, NSSize(width: 960, height: 390))
        XCTAssertTrue(controller.hasDedicatedDragHandle)
        XCTAssertGreaterThan(controller.dragHandleSize?.width ?? 0, 100)
        XCTAssertGreaterThan(controller.dragHandleSize?.height ?? 0, 10)
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

        model.settings.presentationMode = .dynamicIsland
        controller.show()
        XCTAssertEqual(controller.presentationMode, .dynamicIsland)
        XCTAssertEqual(controller.windowSize, NSSize(width: 720, height: 280))
        if let snapshotPath = ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_ISLAND_SNAPSHOT"] {
            let data = try XCTUnwrap(controller.snapshotPNG())
            try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }
        controller.close()
        XCTAssertFalse(controller.isVisible)
    }

    func testFloatingOverlayAutomaticallyFollowsLatestUpdatedCaption() throws {
        guard ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_REAL_OVERLAY"] == "1" else {
            throw XCTSkip("Set LECTURE_ASSISTANT_REAL_OVERLAY=1 to exercise the AppKit overlay.")
        }
        let suiteName = "real-caption-autoscroll-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = CaptionWorkspaceModel(defaults: defaults)
        let sessionID = SessionID()
        let latestRevisionID = TranscriptRevisionID()
        for index in 0..<5 {
            model.append(LiveTranscriptSegment(
                id: "segment-\(index)",
                sessionID: sessionID,
                start: Double(index),
                end: Double(index + 1),
                text: "Caption \(index) has enough words to wrap naturally across multiple lines in the floating window.",
                isFinal: true,
                revisionID: index == 4 ? latestRevisionID : TranscriptRevisionID()
            ))
        }
        let controller = CaptionOverlayWindowController(model: model)

        controller.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(controller.isContentScrolledToBottom, true)

        model.setTranslation(
            "这是最新一条记录的中文翻译，内容更新后浮窗应当继续自动聚焦到底部。",
            for: latestRevisionID
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(controller.isContentScrolledToBottom, true)

        if let snapshotPath = ProcessInfo.processInfo.environment["LECTURE_ASSISTANT_AUTOSCROLL_SNAPSHOT"] {
            let data = try XCTUnwrap(controller.snapshotPNG())
            try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }
        controller.close()
    }
}
