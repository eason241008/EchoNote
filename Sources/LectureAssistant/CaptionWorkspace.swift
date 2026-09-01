import AppKit
import SwiftUI

public enum CaptionLanguageVisibility: String, CaseIterable, Codable, Sendable {
    case bilingual
    case englishOnly
    case simplifiedChineseOnly
}

public enum CaptionPresentationMode: String, CaseIterable, Codable, Sendable {
    case floatingWindow
    case dynamicIsland
}

struct CaptionScrollFollowState: Equatable {
    private(set) var isAtBottom = true
    private(set) var followsLatest = true

    mutating func updateGeometry(isAtBottom: Bool) {
        self.isAtBottom = isAtBottom
    }

    mutating func updateScrollPhase(isIdle: Bool) {
        followsLatest = isIdle ? isAtBottom : false
    }
}

public struct CaptionDisplaySettings: Codable, Equatable, Sendable {
    public var languageVisibility: CaptionLanguageVisibility = .bilingual
    public var presentationMode: CaptionPresentationMode = .floatingWindow
    public var textSize: Double = 32
    public var opacity: Double = 0.92
    public var positionX: Double = 80
    public var positionY: Double = 80
    public var isHidden = false

    private enum CodingKeys: String, CodingKey {
        case languageVisibility, presentationMode, textSize, opacity
        case positionX, positionY, isHidden
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        languageVisibility = try values.decodeIfPresent(
            CaptionLanguageVisibility.self,
            forKey: .languageVisibility
        ) ?? .bilingual
        presentationMode = try values.decodeIfPresent(
            CaptionPresentationMode.self,
            forKey: .presentationMode
        ) ?? .floatingWindow
        textSize = try values.decodeIfPresent(Double.self, forKey: .textSize) ?? 32
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.92
        positionX = try values.decodeIfPresent(Double.self, forKey: .positionX) ?? 80
        positionY = try values.decodeIfPresent(Double.self, forKey: .positionY) ?? 80
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}

@MainActor
public final class CaptionWorkspaceModel: ObservableObject {
    @Published public private(set) var captureState = "尚未录音"
    @Published public private(set) var transcriptionState = "正在检查本地模型"
    @Published public private(set) var translationState = "按需启用"
    @Published public private(set) var postClassTranscriptionState = "等待课程结束"
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
    public func updatePostClassTranscriptionState(_ state: String) {
        postClassTranscriptionState = state
    }

    public func beginSession() {
        segments.removeAll(keepingCapacity: true)
        translations.removeAll(keepingCapacity: true)
        captureState = "准备录音"
        transcriptionState = "正在加载本地模型"
        translationState = "按需启用"
        postClassTranscriptionState = "等待课程结束"
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

    public func recentSegments(limit: Int = 3) -> [LiveTranscriptSegment] {
        Array(segments.suffix(max(1, limit)))
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
    public var presentationMode: CaptionPresentationMode { model.settings.presentationMode }
    var isContentScrolledToBottom: Bool? {
        guard let contentView = window?.contentView,
              let scrollView = firstScrollView(in: contentView),
              let documentView = scrollView.documentView else { return nil }
        let visibleBottom = scrollView.contentView.bounds.maxY
        let documentBottom = documentView.bounds.maxY
        return visibleBottom >= documentBottom - 2
    }

    public func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: frame(for: model.settings.presentationMode),
                styleMask: [.titled, .nonactivatingPanel, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            let hostingView = NSHostingView(rootView: CaptionOverlayView(
                model: model,
                hide: { [weak self] in self?.hide() },
                close: { [weak self] in self?.close() }
            ))
            hostingView.sizingOptions = []
            panel.contentView = hostingView
            panel.delegate = self
            window = panel
        }
        refreshPresentation()
        model.showOverlay()
        window?.orderFrontRegardless()
    }

    public func refreshPresentation() {
        guard let panel = window else { return }
        let target = frame(for: model.settings.presentationMode)
        panel.styleMask = model.settings.presentationMode == .dynamicIsland
            ? [.borderless, .nonactivatingPanel]
            : [.titled, .nonactivatingPanel, .resizable]
        panel.isMovableByWindowBackground = false
        panel.setContentSize(target.size)
        panel.setFrameOrigin(target.origin)
        let fixedFrameSize = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: target.size)
        ).size
        panel.minSize = model.settings.presentationMode == .dynamicIsland
            ? fixedFrameSize
            : panel.frameRect(
                forContentRect: NSRect(x: 0, y: 0, width: 760, height: 320)
            ).size
        panel.maxSize = model.settings.presentationMode == .dynamicIsland
            ? fixedFrameSize
            : NSSize(width: 1_600, height: 900)
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

    public func close() {
        model.quickHide()
        window?.close()
        window = nil
    }
    public func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        if model.settings.presentationMode == .dynamicIsland {
            return frame(for: .dynamicIsland).size
        }
        let minimumFrame = sender.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 760, height: 320)
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
        guard model.settings.presentationMode == .floatingWindow else { return }
        guard let frame = window?.frame else { return }
        model.updateOverlayPosition(x: frame.minX, y: frame.minY)
    }


    private func frame(for mode: CaptionPresentationMode) -> NSRect {
        let size = mode == .dynamicIsland
            ? NSSize(width: 720, height: 280)
            : NSSize(width: 960, height: 390)
        let fallback = NSRect(
            x: model.settings.positionX,
            y: model.settings.positionY,
            width: size.width,
            height: size.height
        )
        let visible = NSScreen.main?.visibleFrame ?? fallback
        if mode == .dynamicIsland {
            return NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 8,
                width: size.width,
                height: size.height
            )
        }
        return NSRect(
            x: min(max(model.settings.positionX, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(model.settings.positionY, visible.minY), max(visible.minY, visible.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let match = firstScrollView(in: child) { return match }
        }
        return nil
    }
}

private struct CaptionOverlayView: View {
    @ObservedObject var model: CaptionWorkspaceModel
    let hide: () -> Void
    let close: () -> Void

    private var isDynamicIsland: Bool {
        model.settings.presentationMode == .dynamicIsland
    }

    private var visibleSegments: [LiveTranscriptSegment] {
        model.recentSegments(limit: isDynamicIsland ? 2 : 3)
    }

    private var latestUpdateToken: String {
        guard let segment = model.segments.last else { return "empty" }
        return [
            segment.id,
            segment.text,
            model.translation(for: segment) ?? "",
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(
                    isDynamicIsland ? "灵动岛字幕" : "实时字幕",
                    systemImage: "captions.bubble.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: hide) {
                    Image(systemName: "minus")
                        .frame(width: 34, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("隐藏字幕浮窗")
                .help("隐藏字幕浮窗")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 34, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭字幕浮窗")
                .help("关闭字幕浮窗")
            }
            .fixedSize(horizontal: false, vertical: true)
            .zIndex(1)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(visibleSegments, id: \.id) { segment in
                            CaptionSegmentText(
                                model: model,
                                segment: segment,
                                fontSize: isDynamicIsland ? min(model.settings.textSize, 18) : nil,
                                maximumLineCount: isDynamicIsland ? 2 : 4
                            )
                            .id(segment.id)
                            if segment.id != visibleSegments.last?.id {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .onAppear { scrollToLatest(using: proxy, animated: false) }
                .onChange(of: latestUpdateToken) {
                    scrollToLatest(using: proxy, animated: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("课堂实时双语字幕")
                .accessibilityValue(model.segments.last?.text ?? "暂无字幕")
            }
            if model.segments.isEmpty {
                Text("等待字幕…")
                    .font(.system(size: model.settings.textSize))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, isDynamicIsland ? 22 : 26)
        .padding(.vertical, isDynamicIsland ? 12 : 22)
        .background(
            RoundedRectangle(
                cornerRadius: isDynamicIsland ? 32 : 20,
                style: .continuous
            )
            .fill(Color.black.opacity(isDynamicIsland ? 0.94 : 0.82))
        )
        .opacity(model.settings.opacity)
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = visibleSegments.last?.id else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

struct CaptionSegmentText: View {
    @ObservedObject var model: CaptionWorkspaceModel
    let segment: LiveTranscriptSegment
    let fontSize: Double?
    let maximumLineCount: Int

    init(
        model: CaptionWorkspaceModel,
        segment: LiveTranscriptSegment,
        fontSize: Double? = nil,
        maximumLineCount: Int = 4
    ) {
        self.model = model
        self.segment = segment
        self.fontSize = fontSize
        self.maximumLineCount = maximumLineCount
    }

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
                        .multilineTextAlignment(.leading)
                }
                if model.settings.languageVisibility != .englishOnly {
                    Text(model.translation(for: segment) ?? model.translationPlaceholder)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }
            .font(.system(size: fontSize ?? model.settings.textSize))
            .foregroundStyle(.white)
            .lineLimit(maximumLineCount)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
