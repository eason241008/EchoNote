import AppKit
import SwiftUI

public enum CaptionLanguageVisibility: String, CaseIterable, Codable, Sendable {
    case bilingual
    case englishOnly
    case simplifiedChineseOnly
}

public struct CaptionDisplaySettings: Codable, Equatable, Sendable {
    public var languageVisibility: CaptionLanguageVisibility = .bilingual
    public var textSize: Double = 32
    public var opacity: Double = 0.92
    public var positionX: Double = 80
    public var positionY: Double = 80
    public var isHidden = false
}

@MainActor
public final class CaptionWorkspaceModel: ObservableObject {
    @Published public private(set) var captureState = "尚未录音"
    @Published public private(set) var transcriptionState = "正在检查本地模型"
    @Published public private(set) var translationState = "按需启用"
    @Published public private(set) var segments: [LiveTranscriptSegment] = []
    @Published public private(set) var translations: [TranscriptRevisionID: String] = [:]
    @Published public var settings: CaptionDisplaySettings {
        didSet { persistSettings() }
    }
    @Published public private(set) var translationAvailable = false
    private let defaults: UserDefaults
    private let settingsKey = "lecture-assistant.caption-display"
    private let settingsMigrationKey = "lecture-assistant.caption-display-v2"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var restored = defaults.data(forKey: settingsKey)
            .flatMap { try? JSONDecoder().decode(CaptionDisplaySettings.self, from: $0) }
            ?? CaptionDisplaySettings()
        if !defaults.bool(forKey: settingsMigrationKey), restored.textSize == 24 {
            restored.textSize = 32
            defaults.set(true, forKey: settingsMigrationKey)
            if let data = try? JSONEncoder().encode(restored) {
                defaults.set(data, forKey: settingsKey)
            }
        }
        settings = restored
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
    public var translationPlaceholder: String {
        translationAvailable ? "等待翻译…" : "未配置中文翻译"
    }

    public func setTranslationAvailable(_ available: Bool) {
        translationAvailable = available
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
    public var windowSize: NSSize? { window?.contentView?.bounds.size }

    public func show() {
        if window == nil {
            let proposed = NSRect(
                x: model.settings.positionX,
                y: model.settings.positionY,
                width: 960,
                height: 260
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
            let hostingView = NSHostingView(rootView: CaptionOverlayView(model: model))
            hostingView.sizingOptions = []
            panel.contentView = hostingView
            panel.setContentSize(NSSize(width: 960, height: 260))
            panel.minSize = panel.frameRect(
                forContentRect: NSRect(x: 0, y: 0, width: 760, height: 220)
            ).size
            panel.delegate = self
            window = panel
        }
        model.showOverlay()
        window?.orderFrontRegardless()
    }

    func snapshotPNG() -> Data? {
        guard let contentView = window?.contentView,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else { return nil }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    public func hide() {
        model.quickHide()
        window?.orderOut(nil)
    }
    public func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        let minimumFrame = sender.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 760, height: 220)
        ).size
        return NSSize(
            width: max(frameSize.width, minimumFrame.width),
            height: max(frameSize.height, minimumFrame.height)
        )
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
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.segments, id: \.id) { segment in
                        CaptionSegmentText(model: model, segment: segment)
                            .id(segment.id)
                    }
                    if model.segments.isEmpty {
                        Text("等待字幕…")
                            .font(.system(size: model.settings.textSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
            }
            .onAppear {
                guard let id = model.segments.last?.id else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: scrollTarget) {
                guard let id = model.segments.last?.id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .opacity(model.settings.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("课堂实时双语字幕")
        .accessibilityValue(model.segments.last?.text ?? "暂无字幕")
    }

    private var scrollTarget: String {
        guard let segment = model.segments.last else { return "" }
        return [
            segment.id,
            segment.text,
            model.translation(for: segment) ?? "",
        ].joined(separator: "\u{1f}")
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
            VStack(alignment: .leading, spacing: 10) {
                if model.settings.languageVisibility != .simplifiedChineseOnly {
                    Text(segment.text)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                if model.settings.languageVisibility != .englishOnly {
                    Text(model.translation(for: segment) ?? model.translationPlaceholder)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .font(.system(size: model.settings.textSize))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
