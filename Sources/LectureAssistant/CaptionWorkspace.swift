import AppKit
import SwiftUI

public enum CaptionLanguageVisibility: String, CaseIterable, Codable, Sendable {
    case bilingual
    case englishOnly
    case simplifiedChineseOnly
}

public struct CaptionDisplaySettings: Codable, Equatable, Sendable {
    public var languageVisibility: CaptionLanguageVisibility = .bilingual
    public var textSize: Double = 24
    public var opacity: Double = 0.92
    public var positionX: Double = 80
    public var positionY: Double = 80
    public var isHidden = false
}

@MainActor
public final class CaptionWorkspaceModel: ObservableObject {
    @Published public private(set) var captureState = "尚未录音"
    @Published public private(set) var transcriptionState = "本地模型已就绪"
    @Published public private(set) var translationState = "按需启用"
    @Published public private(set) var segments: [LiveTranscriptSegment] = []
    @Published public private(set) var translations: [TranscriptRevisionID: String] = [:]
    @Published public var settings: CaptionDisplaySettings {
        didSet { persistSettings() }
    }
    private let defaults: UserDefaults
    private let settingsKey = "lecture-assistant.caption-display"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: settingsKey)
            .flatMap { try? JSONDecoder().decode(CaptionDisplaySettings.self, from: $0) }
            ?? CaptionDisplaySettings()
    }

    public func updateCaptureState(_ state: String) { captureState = state }
    public func updateTranscriptionState(_ state: String) { transcriptionState = state }
    public func updateTranslationState(_ state: String) { translationState = state }

    public func beginSession() {
        segments.removeAll(keepingCapacity: true)
        translations.removeAll(keepingCapacity: true)
        captureState = "准备录音"
        transcriptionState = "正在加载本地模型"
        translationState = "按需启用"
    }

    public func append(_ segment: LiveTranscriptSegment) {
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        } else {
            segments.append(segment)
        }
    }

    public func setTranslation(_ text: String, for revisionID: TranscriptRevisionID) {
        translations[revisionID] = text
    }

    public func translation(for segment: LiveTranscriptSegment) -> String? {
        segment.revisionID.flatMap { translations[$0] }
    }

    public func replaceText(segmentID: String, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let old = segments[index]
        segments[index] = LiveTranscriptSegment(
            id: old.id,
            sessionID: old.sessionID,
            start: old.start,
            end: old.end,
            text: text,
            isFinal: true,
            isGap: old.isGap,
            revisionID: old.revisionID
        )
    }

    public func quickHide() { settings.isHidden = true }
    public func showOverlay() { settings.isHidden = false }

    public func updateOverlayPosition(x: Double, y: Double) {
        settings.positionX = x
        settings.positionY = y
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }
}

@MainActor
public final class CaptionOverlayWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private let model: CaptionWorkspaceModel

    public init(model: CaptionWorkspaceModel) {
        self.model = model
        super.init()
    }

    public var isVisible: Bool { window?.isVisible == true }
    public var windowLevel: NSWindow.Level? { window?.level }
    public var accessibilityLabel: String? {
        window?.contentView?.accessibilityLabel()
    }

    public func show() {
        if window == nil {
            let proposed = NSRect(
                x: model.settings.positionX,
                y: model.settings.positionY,
                width: 720,
                height: 150
            )
            let visible = NSScreen.main?.visibleFrame ?? proposed
            let contentRect = NSRect(
                x: min(max(proposed.minX, visible.minX), max(visible.minX, visible.maxX - proposed.width)),
                y: min(max(proposed.minY, visible.minY), max(visible.minY, visible.maxY - proposed.height)),
                width: proposed.width,
                height: proposed.height
            )
            let panel = NSPanel(
                contentRect: contentRect,
                styleMask: [.titled, .nonactivatingPanel, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = NSColor(
                calibratedRed: 0.12,
                green: 0.17,
                blue: 0.16,
                alpha: 0.96
            )
            panel.isOpaque = false
            panel.contentView = NSHostingView(rootView: CaptionOverlayView(model: model))
            panel.delegate = self
            window = panel
        }
        model.showOverlay()
        window?.orderFrontRegardless()
    }

    public func hide() {
        model.quickHide()
        window?.orderOut(nil)
    }

    public func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    public func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        model.updateOverlayPosition(x: frame.minX, y: frame.minY)
    }
}

private struct CaptionOverlayView: View {
    @ObservedObject var model: CaptionWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.segments.suffix(3), id: \.id) { segment in
                CaptionSegmentText(model: model, segment: segment)
            }
            if model.segments.isEmpty {
                Text("等待字幕…").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .opacity(model.settings.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("课堂实时双语字幕")
        .accessibilityValue(model.segments.last?.text ?? "暂无字幕")
    }
}

struct CaptionSegmentText: View {
    @ObservedObject var model: CaptionWorkspaceModel
    let segment: LiveTranscriptSegment

    var body: some View {
        if segment.isGap {
            Text("[缺失片段]")
                .foregroundStyle(Color(red: 0.93, green: 0.70, blue: 0.45))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if model.settings.languageVisibility != .simplifiedChineseOnly {
                    Text(segment.text)
                }
                if model.settings.languageVisibility != .englishOnly {
                    Text(model.translation(for: segment) ?? "等待翻译…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: model.settings.textSize))
            .foregroundStyle(.white)
            .lineLimit(2)
        }
    }
}
