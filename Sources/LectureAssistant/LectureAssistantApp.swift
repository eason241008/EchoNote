import AppKit
import SwiftUI
import Translation

@MainActor
private final class LectureAssistantAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.presentMainWindow()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            presentMainWindow()
        }
        return true
    }

    private func presentMainWindow() {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.presentMainWindow()
            }
            return
        }
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.minSize = NSSize(width: 940, height: 640)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct EchoNoteApp: App {
    @StateObject private var runtime: ProductionRuntime
    @NSApplicationDelegateAdaptor(LectureAssistantAppDelegate.self)
    private var appDelegate

    init() {
        _runtime = StateObject(wrappedValue: try! ProductionRuntime())
    }

    var body: some Scene {
        WindowGroup("EchoNote 声译") {
            ContentView(
                model: runtime.applicationModel,
                captionWorkspace: runtime.captionWorkspace,
                timetable: runtime.timetable,
                library: runtime.library,
                runtimeSettings: runtime.settings,
                speechModel: runtime.speechModel,
                translationProvider: runtime.translationProvider
            )
        }
        .defaultSize(width: 1120, height: 760)
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case recording
    case schedule
    case captions
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: return "课堂录音"
        case .schedule: return "我的课表"
        case .captions: return "实时字幕"
        case .library: return "课程资料"
        case .settings: return "偏好设置"
        }
    }

    var subtitle: String {
        switch self {
        case .recording: return "开始一场新的课堂记录"
        case .schedule: return "查看课程安排与导入日历"
        case .captions: return "调整字幕显示与翻译"
        case .library: return "查找历史课程和学习资料"
        case .settings: return "管理翻译服务与数据保留"
        }
    }

    var icon: String {
        switch self {
        case .recording: return "waveform.circle.fill"
        case .schedule: return "calendar"
        case .captions: return "captions.bubble.fill"
        case .library: return "books.vertical.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}

private enum AppPalette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color(nsColor: .textBackgroundColor)
    static let primary = Color(nsColor: .labelColor)
    static let sage = Color(nsColor: .controlAccentColor)
    static let sageSoft = Color(nsColor: .controlAccentColor).opacity(0.22)
    static let blueSoft = Color(nsColor: .selectedContentBackgroundColor).opacity(0.28)
    static let coral = Color(red: 0.93, green: 0.43, blue: 0.39)
    static let warningSoft = Color.orange.opacity(0.12)
    static let border = Color(nsColor: .separatorColor).opacity(0.72)
}

struct ContentView: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var captionWorkspace: CaptionWorkspaceModel
    @ObservedObject var timetable: TimetableStore
    @ObservedObject var library: LectureLibraryModel
    @ObservedObject var runtimeSettings: RuntimeSettingsModel
    @ObservedObject var speechModel: SpeechModelManager
    let translationProvider: AppleTranslationProvider
    @AppStorage("lecture-assistant.selected-section")
    private var selectionRawValue = AppSection.recording.rawValue
    @State private var title = "今天的课程"
    @State private var errorMessage: String?
    @State private var translationServiceState = AppleTranslationServiceState.preparing
    @State private var translationConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "zh-Hans")
    )
    @State private var overlayController: CaptionOverlayWindowController?

    private var selection: AppSection {
        get { AppSection(rawValue: selectionRawValue) ?? .recording }
        nonmutating set { selectionRawValue = newValue.rawValue }
    }
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 260)
        } detail: {
            ZStack {
                AppPalette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        pageHeader
                        pageContent
                    }
                    .padding(32)
                    .frame(maxWidth: 980, alignment: .leading)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(AppPalette.sage)
        .frame(minWidth: 940, minHeight: 640)
        .preferredColorScheme(.dark)
        .task {
            await speechModel.refresh()
            captionWorkspace.updateTranscriptionState(
                speechModel.isReady ? "本地模型已就绪" : "本地模型未安装"
            )
            await model.refreshCapturePreflight()
            await timetable.refresh()
        }
        .task {
            for await state in translationProvider.states {
                translationServiceState = state
                captionWorkspace.setTranslationAvailable(state == .ready)
                captionWorkspace.updateTranslationState(state.displayText)
            }
        }
        .translationTask(translationConfiguration) { session in
            await translationProvider.run(
                session: AppleTranslationSessionAdapter(session: session)
            )
        }
        .onChange(of: speechModel.state) {
            captionWorkspace.updateTranscriptionState(
                speechModel.isReady ? "本地模型已就绪" : "本地模型未安装"
            )
            Task { await model.refreshCapturePreflight() }
        }
    }

    private var sidebar: some View {
        ZStack {
            AppPalette.sidebar.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppPalette.sage)
                            .frame(width: 42, height: 42)
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EchoNote 声译")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppPalette.primary)
                        Text("Live Lecture Companion")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)

                VStack(spacing: 6) {
                    ForEach(AppSection.allCases) { section in
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selection = section
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: section.icon)
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 22)
                                Text(section.title)
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(selection == section ? AppPalette.primary : .secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(
                                        selection == section
                                            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.48)
                                            : .clear
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(section.title)
                    }
                }
                .padding(.horizontal, 12)

                Spacer()

                HStack(spacing: 10) {
                    Circle()
                        .fill(model.recordingIndicator.state.isMicrophoneOwned ? AppPalette.coral : AppPalette.sage)
                        .frame(width: 9, height: 9)
                    Text(model.recordingIndicator.state.isMicrophoneOwned ? "正在录音" : "设备就绪")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(selection.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.primary)
            Text(selection.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selection {
        case .recording:
            RecordingPage(
                model: model,
                captionWorkspace: captionWorkspace,
                title: $title,
                errorMessage: $errorMessage,
                run: run
            )
        case .schedule:
            SchedulePage(store: timetable)
        case .captions:
            CaptionPage(model: captionWorkspace) {
                if overlayController == nil {
                    overlayController = CaptionOverlayWindowController(model: captionWorkspace)
                }
                overlayController?.show()
            } hideOverlay: {
                overlayController?.hide()
            }
        case .library:
            LibraryPage(model: library)
        case .settings:
            SettingsPage(
                translationState: translationServiceState,
                runtime: runtimeSettings,
                speechModel: speechModel
            )
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                errorMessage = nil
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RecordingPage: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var captionWorkspace: CaptionWorkspaceModel
    @Binding var title: String
    @Binding var errorMessage: String?
    let run: (@escaping () async throws -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                StatusCard(
                    icon: "mic.fill",
                    title: "录音状态",
                    value: model.recordingIndicator.state.chineseLabel,
                    tint: model.recordingIndicator.state.isMicrophoneOwned ? AppPalette.coral : AppPalette.sage
                )
                StatusCard(
                    icon: "waveform",
                    title: "本地转写",
                    value: model.capturePreflight?.issues.contains(.transcriptionModelUnavailable) == true
                        ? "本地模型未就绪"
                        : captionWorkspace.transcriptionState,
                    tint: Color(red: 0.34, green: 0.48, blue: 0.58)
                )
                StatusCard(
                    icon: "character.book.closed.fill",
                    title: "中文翻译",
                    value: captionWorkspace.translationState,
                    tint: Color(red: 0.55, green: 0.43, blue: 0.62)
                )
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 18) {
                    Label("新建课堂记录", systemImage: "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppPalette.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("课程名称")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("例如：算法与数据结构", text: $title)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(AppPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppPalette.border))
                    }

                    HStack(spacing: 12) {
                        Button {
                            model.prepareSession(title: title)
                            run {
                                await model.refreshCapturePreflight(requestPermission: true)
                            }
                        } label: {
                            Label("准备课堂", systemImage: "checkmark.circle")
                                .frame(minWidth: 108)
                        }
                        .buttonStyle(SecondaryActionButtonStyle())

                        Button {
                            run { try await model.startRecording() }
                        } label: {
                            Label("开始录音", systemImage: "record.circle")
                                .frame(minWidth: 108)
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(!model.canStartRecording)

                        Button("暂停") { run { try await model.pauseRecording() } }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .disabled(model.activeSession?.state != .recording)

                        Button("停止") { run { try await model.stopRecording() } }
                            .buttonStyle(SecondaryActionButtonStyle())
                            .disabled(
                                model.activeSession?.state != .recording
                                    && model.activeSession?.state != .paused
                            )
                    }
                }
            }
            if !model.isRecordingPolicyAcknowledged {
                SoftCard(tint: AppPalette.warningSoft) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("录音前请确认")
                                .font(.headline)
                            Text("请遵守适用法律、学校规定，并在录音前取得必要同意。录音只会在你点击“开始录音”后启动。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("我已了解并同意") {
                                do {
                                    try model.acknowledgeRecordingPolicy()
                                    errorMessage = nil
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                        }
                    }
                }
            }

            if let capturePreflight = model.capturePreflight, !capturePreflight.isReady {
                InlineNotice(
                    icon: "exclamationmark.triangle.fill",
                    text: "开始前还需处理：\(capturePreflight.issues.map(\.chineseName).joined(separator: "、"))",
                    tint: Color(red: 0.68, green: 0.47, blue: 0.24)
                )
            }

            if let errorMessage {
                InlineNotice(icon: "xmark.circle.fill", text: errorMessage, tint: AppPalette.coral)
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("实时中英字幕", systemImage: "captions.bubble.fill")
                            .font(.headline)
                            .foregroundStyle(AppPalette.primary)
                        Spacer()
                        Text(captionWorkspace.transcriptionState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if captionWorkspace.segments.isEmpty {
                        Text(
                            model.activeSession?.state == .recording
                                ? "正在监听麦克风，识别到语音后会显示在这里。"
                                : "开始录音后，英文转写和中文翻译会显示在这里。"
                        )
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(captionWorkspace.segments, id: \.id) { segment in
                            CaptionSegmentText(model: captionWorkspace, segment: segment)
                                .font(.body)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }

            Text("原始课堂音频默认仅在本机保留 30 天，可在“课程资料”中提前删除或延长保留时间。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SchedulePage: View {
    @ObservedObject var store: TimetableStore
    @State private var isImporting = false
    @State private var weekOffset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weekTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppPalette.primary)
                    Text(store.events.isEmpty ? "正在同步墨大课表" : "周视图 · 已同步 \(store.events.count) 节课程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    weekOffset -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 18)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("上一周")

                Button("本周") {
                    withAnimation(.easeInOut(duration: 0.2)) { weekOffset = 0 }
                }
                .buttonStyle(SecondaryActionButtonStyle())

                Button {
                    weekOffset += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 18)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("下一周")

                Button {
                    isImporting = true
                } label: {
                    Label("导入课表", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }

            if store.events.isEmpty {
                SoftCard {
                    VStack(spacing: 18) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(AppPalette.sage)
                        Text("还没有课程安排")
                            .font(.title3.weight(.semibold))
                        Text("你可以导入 ICS 日历文件；同步成功后会显示为周时间表。")
                            .foregroundStyle(.secondary)
                        Button("选择日历文件") { isImporting = true }
                            .buttonStyle(SecondaryActionButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 46)
                }
            } else {
                WeeklyTimetableView(events: store.events, weekOffset: $weekOffset)
            }

            if let importMessage = store.statusMessage {
                InlineNotice(icon: "checkmark.circle.fill", text: importMessage, tint: AppPalette.sage)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.calendarEvent, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try store.importCalendar(String(contentsOf: url, encoding: .utf8))
            } catch {}
        }
    }

    private var weekTitle: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne") ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let date = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: Date()) ?? Date()
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date),
              let end = calendar.date(byAdding: .day, value: 4, to: interval.start) else {
            return "本周课程"
        }
        return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

private struct ScheduleEventRow: View {
    let event: ICSCourseEvent

    var body: some View {
        SoftCard {
            HStack(spacing: 18) {
                VStack(spacing: 3) {
                    Text(event.startsAt.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.sage)
                    Text(event.startsAt.formatted(.dateTime.day()))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(AppPalette.primary)
                }
                .frame(width: 54)

                Rectangle()
                    .fill(AppPalette.sageSoft)
                    .frame(width: 1, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(event.summary)
                        .font(.headline)
                        .foregroundStyle(AppPalette.primary)
                    Text("\(event.startsAt.formatted(date: .omitted, time: .shortened)) – \(event.endsAt.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let location = event.location, !location.isEmpty {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct CaptionPage: View {
    @ObservedObject var model: CaptionWorkspaceModel
    let showOverlay: () -> Void
    let hideOverlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                StatusCard(icon: "mic.fill", title: "录音", value: model.captureState.chineseStatus, tint: AppPalette.sage)
                StatusCard(icon: "waveform", title: "英文转写", value: model.transcriptionState.chineseStatus, tint: Color(red: 0.34, green: 0.48, blue: 0.58))
                StatusCard(icon: "character.book.closed", title: "中文翻译", value: model.translationState.chineseStatus, tint: Color(red: 0.55, green: 0.43, blue: 0.62))
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("字幕显示")
                        .font(.headline)
                        .foregroundStyle(AppPalette.primary)

                    Picker("显示语言", selection: $model.settings.languageVisibility) {
                        Text("中英双语").tag(CaptionLanguageVisibility.bilingual)
                        Text("仅英文").tag(CaptionLanguageVisibility.englishOnly)
                        Text("仅中文").tag(CaptionLanguageVisibility.simplifiedChineseOnly)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("文字大小  \(Int(model.settings.textSize))")
                                .font(.caption)
                            Slider(value: $model.settings.textSize, in: 18...64)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("背景透明度  \(Int(model.settings.opacity * 100))%")
                                .font(.caption)
                            Slider(value: $model.settings.opacity, in: 0.4...1)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("显示字幕浮窗", action: showOverlay)
                            .buttonStyle(PrimaryActionButtonStyle())
                        Button("快速隐藏", action: hideOverlay)
                            .buttonStyle(SecondaryActionButtonStyle())
                    }
                }
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("课堂文字记录")
                        .font(.headline)
                        .foregroundStyle(AppPalette.primary)
                    if model.segments.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .foregroundStyle(AppPalette.sage)
                            Text("录音开始后，实时字幕会显示在这里。")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 26)
                    } else {
                        ForEach(model.segments, id: \.id) { segment in
                            HStack(alignment: .top, spacing: 12) {
                                Text(formatTime(segment.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                CaptionSegmentText(model: model, segment: segment)
                                    .font(.body)
                                    .foregroundStyle(segment.isGap ? AppPalette.coral : AppPalette.primary)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

private struct LibraryPage: View {
    @ObservedObject var model: LectureLibraryModel
    @State private var query = ""
    @State private var confirmDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TextField("搜索字幕、翻译、书签和笔记", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search(query) }
                Button("搜索") { model.search(query) }
                    .buttonStyle(PrimaryActionButtonStyle())
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SecondaryActionButtonStyle())
            }

            HStack(spacing: 16) {
                StatusCard(icon: "clock.arrow.circlepath", title: "课程记录", value: "\(model.sessions.count) 场", tint: AppPalette.sage)
                StatusCard(
                    icon: "text.quote",
                    title: "字幕片段",
                    value: "\(model.sessions.reduce(0) { $0 + $1.transcriptCount }) 条",
                    tint: Color(red: 0.34, green: 0.48, blue: 0.58)
                )
                StatusCard(
                    icon: "character.book.closed",
                    title: "中文翻译",
                    value: "\(model.sessions.reduce(0) { $0 + $1.translationCount }) 条",
                    tint: Color(red: 0.55, green: 0.43, blue: 0.62)
                )
            }

            if !model.searchResults.isEmpty {
                SoftCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("搜索结果").font(.headline)
                        ForEach(model.searchResults, id: \.contentID) { result in
                            Button {
                                model.selectSearchResult(result)
                            } label: {
                                HStack {
                                    Image(systemName: result.contentType.icon)
                                    Text(result.snippet)
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                SoftCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("历史课程").font(.headline)
                        if model.sessions.isEmpty {
                            Text("完成课堂录音后，记录会显示在这里。")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(model.sessions) { session in
                                Button {
                                    model.selectedSessionID = session.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(session.title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .lineLimit(1)
                                            Spacer()
                                            Text(session.state.chineseLibraryLabel)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("\(session.transcriptCount) 条字幕 · \(session.translationCount) 条翻译")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        model.selectedSessionID == session.id
                                            ? AppPalette.sageSoft
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(width: 300)

                SoftCard {
                    if let session = model.selectedSession,
                       let snapshot = model.selectedSnapshot {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title).font(.title3.weight(.semibold))
                                    Text(session.updatedAt.formatted(date: .long, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu("导出") {
                                    ForEach(LibraryExportFormat.allCases) { format in
                                        Button(format.title) { model.exportSelected(as: format) }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                Button("删除") { confirmDeletion = true }
                                    .buttonStyle(SecondaryActionButtonStyle())
                            }
                            Divider()
                            if snapshot.segments.isEmpty {
                                Text("这场课程还没有可用字幕。")
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 24)
                            } else {
                                ForEach(Array(snapshot.segments.enumerated()), id: \.element.id) { index, segment in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(format: "%02d:%02d", Int(segment.start) / 60, Int(segment.start) % 60))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(segment.isGap ? "[缺失片段]" : segment.text)
                                            .foregroundStyle(segment.isGap ? AppPalette.coral : AppPalette.primary)
                                        if snapshot.translations.indices.contains(index) {
                                            let translation = snapshot.translations[index]
                                            Text(translation.text)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 5)
                                }
                            }
                        }
                    } else {
                        Text("从左侧选择一场课程。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
            }

            if let message = model.statusMessage {
                InlineNotice(icon: "info.circle.fill", text: message, tint: AppPalette.sage)
            }
        }
        .confirmationDialog("永久删除这场课程及其本地音频？", isPresented: $confirmDeletion) {
            Button("删除", role: .destructive) { model.deleteSelectedSession() }
            Button("取消", role: .cancel) {}
        }
        .task { model.refresh() }
    }
}

private struct SettingsPage: View {
    let translationState: AppleTranslationServiceState
    @ObservedObject var runtime: RuntimeSettingsModel
    @ObservedObject var speechModel: SpeechModelManager
    @State private var timetableURL = ""
    @State private var modelErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                StatusCard(
                    icon: "waveform",
                    title: "离线转写模型",
                    value: speechModel.statusText,
                    tint: speechModel.isReady ? AppPalette.sage : AppPalette.coral
                )
                StatusCard(
                    icon: "externaldrive.fill",
                    title: "本地数据",
                    value: runtime.storageSize.formattedBytes,
                    tint: Color(red: 0.34, green: 0.48, blue: 0.58)
                )
                StatusCard(
                    icon: "calendar",
                    title: "课表订阅",
                    value: runtime.timetableURL?.host ?? "未配置",
                    tint: Color(red: 0.55, green: 0.43, blue: 0.62)
                )
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("本地英文转写模型", systemImage: "waveform")
                        .font(.headline)
                    Text("Nemotron Streaming 0.6B · 1120 ms · 约 600 MB。使用 Apple Neural Engine 进行低延迟本地英文转写。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if case let .downloading(progress) = speechModel.state {
                        ProgressView(value: progress)
                        Text("正在下载 \(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if case .verifying = speechModel.state {
                        ProgressView("正在验证本地模型…")
                    }
                    HStack(spacing: 12) {
                        if speechModel.isReady {
                            Button("重新验证") {
                                Task { await speechModel.refresh() }
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                            Button("删除模型", role: .destructive) {
                                Task {
                                    do {
                                        try await speechModel.remove()
                                        modelErrorMessage = nil
                                    } catch {
                                        modelErrorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                        } else {
                            Button("下载并验证模型") {
                                Task {
                                    do {
                                        try await speechModel.downloadAfterUserConfirmation()
                                        modelErrorMessage = nil
                                    } catch {
                                        modelErrorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(PrimaryActionButtonStyle())
                            .disabled(speechModel.isBusy)
                        }
                    }
                    if let modelErrorMessage {
                        InlineNotice(
                            icon: "exclamationmark.triangle.fill",
                            text: modelErrorMessage,
                            tint: AppPalette.coral
                        )
                    }
                }
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Apple 本地中文翻译", systemImage: "character.book.closed.fill")
                        .font(.headline)
                    Text(translationState.displayText)
                        .font(.system(size: 15, weight: .medium))
                    Text("英文到简体中文的翻译由 macOS Translation framework 在本机完成，不使用 DeepSeek、OMP 配置或 API 密钥。首次使用时，系统可能要求下载语言包。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if case .unavailable = translationState {
                        InlineNotice(
                            icon: "exclamationmark.triangle.fill",
                            text: "请确认已联网并允许 macOS 下载英语和简体中文语言包，然后重新启动 EchoNote。",
                            tint: AppPalette.coral
                        )
                    }
                }
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label("存储与保留", systemImage: "internaldrive.fill")
                        .font(.headline)
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("原始音频保留天数")
                            Text(runtime.retentionDays == 0 ? "录音完成后可立即清理" : "当前保留 \(runtime.retentionDays) 天")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { runtime.retentionDays },
                                set: { runtime.setRetentionDays($0) }
                            ),
                            in: 0...365,
                            step: 5
                        ) {
                            Text("\(runtime.retentionDays) 天").monospacedDigit()
                        }
                        .fixedSize()
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("应用数据目录")
                            Text(runtime.applicationSupportURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("在 Finder 中显示") { runtime.revealDataFolder() }
                            .buttonStyle(SecondaryActionButtonStyle())
                    }
                }
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("课表订阅", systemImage: "calendar.badge.clock")
                        .font(.headline)
                    TextField("https://example.edu/calendar.ics", text: $timetableURL)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("仅保存在本机；应用启动时自动刷新，离线时显示上次缓存。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("保存并同步") {
                            Task { await runtime.setTimetableURL(timetableURL) }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(timetableURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            timetableURL = runtime.timetableURL?.absoluteString ?? ""
        }
        .task { runtime.refresh() }
    }
}

private struct StatusCard: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(tint.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.system(size: 17, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppPalette.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(AppPalette.border))
    }
}

private struct SoftCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    init(tint: Color = AppPalette.card, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppPalette.border))
    }
}

private struct InlineNotice: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(AppPalette.primary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveButtonBody(
            configuration: configuration,
            foreground: .white,
            background: AppPalette.sage,
            border: AppPalette.sage.opacity(0.9),
            weight: .semibold
        )
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveButtonBody(
            configuration: configuration,
            foreground: AppPalette.primary,
            background: Color(nsColor: .controlBackgroundColor),
            border: AppPalette.border,
            weight: .medium
        )
    }
}

private struct InteractiveButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let foreground: Color
    let background: Color
    let border: Color
    let weight: Font.Weight
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: weight))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(background.opacity(configuration.isPressed ? 0.72 : isHovered ? 0.9 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? foreground.opacity(0.34) : border, lineWidth: isHovered ? 1.2 : 0.8)
            )
            .shadow(
                color: isEnabled ? background.opacity(isHovered ? 0.34 : 0.16) : .clear,
                radius: configuration.isPressed ? 2 : isHovered ? 9 : 4,
                y: configuration.isPressed ? 1 : isHovered ? 4 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.965 : isHovered ? 1.025 : 1)
            .offset(y: configuration.isPressed ? 1 : isHovered ? -1 : 0)
            .saturation(isEnabled ? 1 : 0.25)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

private extension RecordingIndicatorState {
    var chineseLabel: String {
        switch self {
        case .hidden: return "尚未开始"
        case .recording: return "正在录音"
        case .paused: return "已暂停"
        case .stopping: return "正在停止"
        case .completed: return "录音完成"
        case .interrupted: return "录音已中断"
        }
    }
}

private extension CapturePreflightIssue {
    var chineseName: String {
        switch self {
        case .microphonePermissionRequired: return "需要麦克风权限"
        case .microphonePermissionDenied: return "麦克风权限被拒绝"
        case .selectedDeviceUnavailable: return "输入设备不可用"
        case .storageUnavailable: return "存储空间不可用"
        case .transcriptionModelUnavailable: return "本地转写模型未就绪"
        }
    }
}

private extension String {
    var chineseStatus: String {
        switch self {
        case "Not capturing": return "尚未开始"
        case "Waiting for local model": return "等待本地模型"
        case "English-only": return "仅英文模式"
        case "Recording": return "正在录音"
        case "Ready": return "已就绪"
        case "Translating": return "正在翻译"
        default: return self
        }
    }
}

private extension SearchContentType {
    var icon: String {
        switch self {
        case .transcript: return "text.quote"
        case .translation: return "character.book.closed"
        case .bookmark: return "bookmark.fill"
        case .note: return "note.text"
        }
    }
}

private extension SessionState {
    var chineseLibraryLabel: String {
        switch self {
        case .prepared: return "已准备"
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .interrupted: return "已中断"
        case .completed: return "已完成"
        }
    }
}

private extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
