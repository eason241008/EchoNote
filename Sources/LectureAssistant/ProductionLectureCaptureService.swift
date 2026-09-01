import Foundation

@MainActor
public final class ProductionLectureCaptureService: LectureCaptureService, @unchecked Sendable {
    private struct PostClassJob: Equatable, Sendable {
        let sessionID: SessionID
        let title: String
    }

    private let storage: SessionStorage
    private let database: LectureDatabase
    private let modelFolderProvider: () -> URL?
    private let captionWorkspace: CaptionWorkspaceModel
    private let translationProvider: any SimplifiedChineseTranslationProviding

    private var capture: AVFoundationLectureCaptureService?
    private var transcription: LiveTranscriptionPipeline?
    private var transcriptionPipelines: [SessionID: LiveTranscriptionPipeline] = [:]
    private var translation: TranslationPipeline?
    private var frameTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    private var translationStateTask: Task<Void, Never>?
    private var translationResultTask: Task<Void, Never>?
    private var retiredPipelineTasks: [Task<Void, Never>] = []
    private var postClassTask: Task<Void, Never>?
    private var postClassTaskToken: UUID?
    private var pendingPostClassJobs: [PostClassJob] = []
    private var postClassPausedForRecording = false
    private var currentPreparation: LectureCapturePreparation?
    private var cachedRecognizer: WhisperKitSpeechRecognizer?
    private var cachedModelFolder: URL?
    private var recognizerLoadTask: Task<WhisperKitSpeechRecognizer, Error>?
    private var recognizerLoadFolder: URL?

    public init(
        storage: SessionStorage,
        database: LectureDatabase,
        modelFolder: URL,
        captionWorkspace: CaptionWorkspaceModel,
        translationProvider: any SimplifiedChineseTranslationProviding
    ) {
        self.storage = storage
        self.database = database
        modelFolderProvider = { modelFolder }
        self.captionWorkspace = captionWorkspace
        self.translationProvider = translationProvider
    }

    public init(
        storage: SessionStorage,
        database: LectureDatabase,
        modelFolderProvider: @escaping () -> URL?,
        captionWorkspace: CaptionWorkspaceModel,
        translationProvider: any SimplifiedChineseTranslationProviding
    ) {
        self.storage = storage
        self.database = database
        self.modelFolderProvider = modelFolderProvider
        self.captionWorkspace = captionWorkspace
        self.translationProvider = translationProvider
    }

    public func prepare(_ preparation: LectureCapturePreparation) async throws {
        postClassPausedForRecording = true
        postClassTask?.cancel()
        postClassTask = nil
        postClassTaskToken = nil
        cancelTasks()
        currentPreparation = preparation
        captionWorkspace.beginSession()
        try SQLiteLectureSessionRepository(database: database).save(preparation.session)
        try await storage.createSession(manifest: SessionManifest(
            sessionID: preparation.session.id,
            state: .prepared,
            selectedDeviceID: String(preparation.deviceID),
            courseID: preparation.session.courseID,
            transcriptionModel: SpeechModelDescriptor.largeV3Compressed.id
        ))

        captionWorkspace.updateCaptureState("准备录音")
        captionWorkspace.updateTranscriptionState("正在加载本地模型")
        let recognizer = try await loadRecognizer()
        let (transcription, translation) = await makePipelines(
            session: preparation.session,
            recognizer: recognizer
        )
        let capture = AVFoundationLectureCaptureService(storage: storage)
        try await capture.prepare(preparation)

        self.capture = capture
        self.transcription = transcription
        transcriptionPipelines = [preparation.session.id: transcription]
        self.translation = translation
        captionWorkspace.setTranslationAvailable(true)
        captionWorkspace.updateTranscriptionState("本地模型已就绪")
        captionWorkspace.updateTranslationState("Apple 本地翻译")

        frameTask = Task { [weak self, capture] in
            for await frame in capture.frames {
                guard !Task.isCancelled else { break }
                await self?.consume(frame)
            }
        }
        startObservers(
            for: preparation.session,
            transcription: transcription,
            translation: translation
        )
    }

    public func start() async throws {
        guard let capture else { throw AVFoundationCaptureError.notPrepared }
        try await capture.start()
        captionWorkspace.updateCaptureState("正在录音")
        try updateCurrentSessionState(.recording)
    }

    public func prewarmRecognizer() async throws {
        _ = try await loadRecognizer()
    }

    public func pause() async throws {
        try await capture?.pause()
        captionWorkspace.updateCaptureState("已暂停")
        try updateCurrentSessionState(.paused)
    }

    public func resume() async throws {
        try await capture?.resume()
        captionWorkspace.updateCaptureState("正在录音")
        try updateCurrentSessionState(.recording)
    }

    public func rollover(to session: LectureSession) async throws {
        guard let capture, let currentPreparation else {
            throw AVFoundationCaptureError.notPrepared
        }
        let currentState = currentPreparation.session.state
        let recognizer = try await loadRecognizer()
        var nextSession = session
        nextSession.state = currentState
        nextSession.updatedAt = LectureTimestamp()
        let nextPreparation = LectureCapturePreparation(
            session: nextSession,
            deviceID: currentPreparation.deviceID
        )

        try SQLiteLectureSessionRepository(database: database).save(nextSession)
        try await storage.createSession(manifest: SessionManifest(
            sessionID: nextSession.id,
            state: nextSession.state,
            selectedDeviceID: String(currentPreparation.deviceID),
            courseID: nextSession.courseID,
            transcriptionModel: SpeechModelDescriptor.largeV3Compressed.id
        ))
        let (nextTranscription, nextTranslation) = await makePipelines(
            session: nextSession,
            recognizer: recognizer
        )
        let previousSession = currentPreparation.session
        let previousTranscription = transcription
        let previousTranslation = translation
        let previousSegmentTask = segmentTask
        let previousTranslationStateTask = translationStateTask
        let previousTranslationResultTask = translationResultTask

        transcriptionPipelines[nextSession.id] = nextTranscription
        do {
            try await capture.rollover(to: nextPreparation)
        } catch {
            transcriptionPipelines[nextSession.id] = nil
            throw error
        }
        transcription = nextTranscription
        translation = nextTranslation
        startObservers(
            for: nextSession,
            transcription: nextTranscription,
            translation: nextTranslation
        )
        self.currentPreparation = nextPreparation
        try markSessionCompleted(previousSession)
        switch currentState {
        case .paused:
            captionWorkspace.updateCaptureState("已暂停")
        default:
            captionWorkspace.updateCaptureState("正在录音")
        }
        captionWorkspace.updateTranscriptionState("本地模型已就绪")
        captionWorkspace.updateTranslationState("Apple 本地翻译")
        retirePipeline(
            session: previousSession,
            transcription: previousTranscription,
            translation: previousTranslation,
            segmentTask: previousSegmentTask,
            translationStateTask: previousTranslationStateTask,
            translationResultTask: previousTranslationResultTask
        )
    }

    public func stop() async throws {
        guard let capture else { return }
        try await capture.stop()
        _ = await frameTask?.result
        await transcription?.finish()
        _ = await segmentTask?.result
        await translation?.finish()
        _ = await translationStateTask?.result
        _ = await translationResultTask?.result
        while let retiredTask = retiredPipelineTasks.first {
            retiredPipelineTasks.removeFirst()
            _ = await retiredTask.result
        }
        captionWorkspace.updateCaptureState("已完成")
        if capture.droppedFrameCount > 0 {
            captionWorkspace.updateTranscriptionState(
                "实时字幕缓冲溢出 \(capture.droppedFrameCount) 帧；原始音频已完整保存"
            )
        } else {
            captionWorkspace.updateTranscriptionState("转写完成 · 音频零丢帧")
        }
        if let session = currentPreparation?.session {
            try markSessionCompleted(session)
        }
        postClassPausedForRecording = false
        enqueuePostClassTranscription()
    }

    private func makeTranslationPipeline() -> TranslationPipeline {
        TranslationPipeline(
            provider: translationProvider,
            repository: SQLiteTranslationRepository(database: database),
            batchingDelay: .milliseconds(80)
        )
    }

    private func makePipelines(
        session: LectureSession,
        recognizer: WhisperKitSpeechRecognizer
    ) async -> (LiveTranscriptionPipeline, TranslationPipeline) {
        let transcription = LiveTranscriptionPipeline(
            sessionID: session.id,
            recognizer: recognizer,
            repository: SQLiteTranscriptRevisionRepository(database: database),
            finalWindowSeconds: 10,
            partialWindowSeconds: 4
        )
        await transcription.updatePrompt(session.title)
        return (transcription, makeTranslationPipeline())
    }

    private func loadRecognizer() async throws -> WhisperKitSpeechRecognizer {
        guard let modelFolder = modelFolderProvider() else {
            throw SpeechModelManagerError.invalidModelDirectory
        }
        if let cachedRecognizer, cachedModelFolder == modelFolder {
            return cachedRecognizer
        }
        if let recognizerLoadTask, recognizerLoadFolder == modelFolder {
            return try await recognizerLoadTask.value
        }
        let task = Task {
            try await WhisperKitSpeechRecognizer(modelFolder: modelFolder)
        }
        recognizerLoadTask = task
        recognizerLoadFolder = modelFolder
        do {
            let recognizer = try await task.value
            cachedRecognizer = recognizer
            cachedModelFolder = modelFolder
            recognizerLoadTask = nil
            recognizerLoadFolder = nil
            return recognizer
        } catch {
            recognizerLoadTask = nil
            recognizerLoadFolder = nil
            throw error
        }
    }

    private func enqueuePostClassTranscription() {
        guard let session = currentPreparation?.session else { return }
        enqueuePostClassTranscription(for: session)
    }

    private func enqueuePostClassTranscription(for session: LectureSession) {
        let job = PostClassJob(sessionID: session.id, title: session.title)
        if !pendingPostClassJobs.contains(job) {
            pendingPostClassJobs.append(job)
        }
        startNextPostClassTranscriptionIfPossible()
    }

    private func startNextPostClassTranscriptionIfPossible() {
        guard !postClassPausedForRecording,
              postClassTask == nil,
              let recognizer = cachedRecognizer,
              let job = pendingPostClassJobs.first else { return }
        captionWorkspace.updatePostClassTranscriptionState(
            "正在后台生成课后整课校对稿：\(job.title)"
        )
        let service = PostClassTranscriptionService(
            storage: storage,
            recognizer: recognizer
        )
        let taskToken = UUID()
        postClassTaskToken = taskToken
        postClassTask = Task { [weak self] in
            do {
                let document = try await service.generate(
                    sessionID: job.sessionID,
                    title: job.title
                )
                guard !Task.isCancelled else { return }
                self?.finishPostClassTranscription(
                    job: job,
                    taskToken: taskToken,
                    message: "课后校对稿已保存：\(job.title)（\(document.segments.count) 段）"
                )
            } catch is CancellationError {
                self?.handlePostClassCancellation(taskToken: taskToken)
                return
            } catch {
                self?.finishPostClassTranscription(
                    job: job,
                    taskToken: taskToken,
                    message: "课后校对稿生成失败（\(job.title)）：\(error.localizedDescription)"
                )
            }
        }
    }

    private func handlePostClassCancellation(taskToken: UUID) {
        guard postClassTaskToken == taskToken else { return }
        postClassTask = nil
        postClassTaskToken = nil
        startNextPostClassTranscriptionIfPossible()
    }

    private func finishPostClassTranscription(
        job: PostClassJob,
        taskToken: UUID,
        message: String
    ) {
        guard postClassTaskToken == taskToken else { return }
        pendingPostClassJobs.removeAll { $0.sessionID == job.sessionID }
        captionWorkspace.updatePostClassTranscriptionState(message)
        postClassTask = nil
        postClassTaskToken = nil
        startNextPostClassTranscriptionIfPossible()
    }


    private func updateTranslationState(_ state: TranslationPipelineState) {
        switch state {
        case .englishOnly:
            captionWorkspace.updateTranslationState("仅英文")
        case let .queued(count):
            captionWorkspace.updateTranslationState("等待翻译（\(count)）")
        case let .translating(count):
            captionWorkspace.updateTranslationState("正在翻译（\(count)）")
        case .translated:
            captionWorkspace.updateTranslationState("翻译完成")
        case let .failed(retryable, message):
            captionWorkspace.updateTranslationState(retryable ? "翻译暂时失败，可重试" : message)
        }
    }

    private func startObservers(
        for session: LectureSession,
        transcription: LiveTranscriptionPipeline,
        translation: TranslationPipeline
    ) {
        segmentTask = Task { [weak self, transcription, translation] in
            for await segment in transcription.segments {
                guard !Task.isCancelled else { break }
                let visibleSegment = LiveTranscriptSegment(
                    id: "\(session.id.rawValue.uuidString)-\(segment.id)",
                    sessionID: segment.sessionID,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    isFinal: segment.isFinal,
                    isGap: segment.isGap,
                    revisionID: segment.revisionID
                )
                await MainActor.run {
                    self?.captionWorkspace.append(visibleSegment)
                    self?.captionWorkspace.updateTranscriptionState(
                        segment.isGap ? "发现缺失片段" : "正在转写"
                    )
                }
                if segment.isFinal, !segment.isGap, let revisionID = segment.revisionID {
                    await translation.enqueue(PendingTranslationRevision(
                        sessionID: segment.sessionID,
                        revisionID: revisionID,
                        text: segment.text
                    ))
                }
            }
        }
        translationStateTask = Task { [weak self, translation] in
            for await state in translation.states {
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.updateTranslationState(state) }
            }
        }
        translationResultTask = Task { [weak self, translation] in
            for await result in translation.results {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.captionWorkspace.setTranslation(
                        result.text,
                        for: result.revisionID
                    )
                }
            }
        }
    }

    private func consume(_ frame: CapturedAudioFrame) async {
        if let sessionID = frame.sessionID,
           let pipeline = transcriptionPipelines[sessionID] {
            await pipeline.consume(frame)
        } else {
            await transcription?.consume(frame)
        }
    }

    private func retirePipeline(
        session: LectureSession,
        transcription: LiveTranscriptionPipeline?,
        translation: TranslationPipeline?,
        segmentTask: Task<Void, Never>?,
        translationStateTask: Task<Void, Never>?,
        translationResultTask: Task<Void, Never>?
    ) {
        let task = Task { [weak self] in
            await transcription?.finish()
            _ = await segmentTask?.result
            await translation?.finish()
            _ = await translationStateTask?.result
            _ = await translationResultTask?.result
            await MainActor.run {
                self?.enqueuePostClassTranscription(for: session)
                self?.transcriptionPipelines[session.id] = nil
            }
        }
        retiredPipelineTasks.append(task)
    }

    private func updateCurrentSessionState(_ state: SessionState) throws {
        guard let existingPreparation = currentPreparation else { return }
        var session = existingPreparation.session
        session.state = state
        session.updatedAt = LectureTimestamp()
        currentPreparation = LectureCapturePreparation(
            session: session,
            deviceID: existingPreparation.deviceID
        )
        try SQLiteLectureSessionRepository(database: database).save(session)
    }

    private func markSessionCompleted(_ session: LectureSession) throws {
        var completed = session
        completed.state = .completed
        completed.updatedAt = LectureTimestamp()
        try SQLiteLectureSessionRepository(database: database).save(completed)
    }

    private func cancelTasks() {
        frameTask?.cancel()
        segmentTask?.cancel()
        translationStateTask?.cancel()
        translationResultTask?.cancel()
        retiredPipelineTasks.forEach { $0.cancel() }
        frameTask = nil
        segmentTask = nil
        translationStateTask = nil
        translationResultTask = nil
        retiredPipelineTasks.removeAll(keepingCapacity: false)
        transcriptionPipelines.removeAll(keepingCapacity: false)
    }
}
