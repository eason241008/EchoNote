import Foundation

@MainActor
public final class ProductionLectureCaptureService: LectureCaptureService, @unchecked Sendable {
    private let storage: SessionStorage
    private let database: LectureDatabase
    private let modelFolder: URL
    private let captionWorkspace: CaptionWorkspaceModel
    private let translationProvider: any SimplifiedChineseTranslationProviding

    private var capture: AVFoundationLectureCaptureService?
    private var transcription: LiveTranscriptionPipeline?
    private var translation: TranslationPipeline?
    private var frameTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    private var translationStateTask: Task<Void, Never>?
    private var translationResultTask: Task<Void, Never>?
    private var currentPreparation: LectureCapturePreparation?

    public init(
        storage: SessionStorage,
        database: LectureDatabase,
        modelFolder: URL,
        captionWorkspace: CaptionWorkspaceModel,
        translationProvider: any SimplifiedChineseTranslationProviding
    ) {
        self.storage = storage
        self.database = database
        self.modelFolder = modelFolder
        self.captionWorkspace = captionWorkspace
        self.translationProvider = translationProvider
    }

    public func prepare(_ preparation: LectureCapturePreparation) async throws {
        cancelTasks()
        currentPreparation = preparation
        captionWorkspace.beginSession()
        try SQLiteLectureSessionRepository(database: database).save(preparation.session)
        try await storage.createSession(manifest: SessionManifest(
            sessionID: preparation.session.id,
            state: .prepared,
            selectedDeviceID: String(preparation.deviceID),
            courseID: preparation.session.courseID,
            transcriptionModel: SpeechModelDescriptor.smallEnglish.id
        ))

        captionWorkspace.updateCaptureState("准备录音")
        captionWorkspace.updateTranscriptionState("正在加载本地模型")
        let recognizer = try await WhisperKitSpeechRecognizer(modelFolder: modelFolder)
        let transcriptRepository = SQLiteTranscriptRevisionRepository(database: database)
        let transcription = LiveTranscriptionPipeline(
            sessionID: preparation.session.id,
            recognizer: recognizer,
            repository: transcriptRepository
        )
        await transcription.updatePrompt(preparation.session.title)
        let translation = makeTranslationPipeline()
        let capture = AVFoundationLectureCaptureService(storage: storage)
        try await capture.prepare(preparation)

        self.capture = capture
        self.transcription = transcription
        self.translation = translation
        captionWorkspace.setTranslationAvailable(true)
        captionWorkspace.updateTranscriptionState("本地模型已就绪")
        captionWorkspace.updateTranslationState("Apple 本地翻译")

        frameTask = Task { [capture, transcription] in
            for await frame in capture.frames {
                guard !Task.isCancelled else { break }
                await transcription.consume(frame)
            }
        }
        segmentTask = Task { [weak self, transcription] in
            for await segment in transcription.segments {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.captionWorkspace.append(segment)
                    self?.captionWorkspace.updateTranscriptionState(
                        segment.isGap ? "发现缺失片段" : "正在转写"
                    )
                }
                if segment.isFinal, !segment.isGap, let revisionID = segment.revisionID {
                    await self?.translation?.enqueue(PendingTranslationRevision(
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

    public func start() async throws {
        guard let capture else { throw AVFoundationCaptureError.notPrepared }
        try await capture.start()
        captionWorkspace.updateCaptureState("正在录音")
        if var session = currentPreparation?.session {
            session.state = .recording
            session.updatedAt = LectureTimestamp()
            try SQLiteLectureSessionRepository(database: database).save(session)
        }
    }

    public func pause() async throws {
        try await capture?.pause()
        captionWorkspace.updateCaptureState("已暂停")
        if var session = currentPreparation?.session {
            session.state = .paused
            session.updatedAt = LectureTimestamp()
            try SQLiteLectureSessionRepository(database: database).save(session)
        }
    }

    public func resume() async throws {
        try await capture?.resume()
        captionWorkspace.updateCaptureState("正在录音")
        if var session = currentPreparation?.session {
            session.state = .recording
            session.updatedAt = LectureTimestamp()
            try SQLiteLectureSessionRepository(database: database).save(session)
        }
    }

    public func stop() async throws {
        guard let capture else { return }
        try await capture.stop()
        await transcription?.finish()
        _ = await segmentTask?.result
        await translation?.finish()
        _ = await translationStateTask?.result
        _ = await translationResultTask?.result
        captionWorkspace.updateCaptureState("已完成")
        captionWorkspace.updateTranscriptionState("转写完成")
        if var session = currentPreparation?.session {
            session.state = .completed
            session.updatedAt = LectureTimestamp()
            try SQLiteLectureSessionRepository(database: database).save(session)
        }
    }

    private func makeTranslationPipeline() -> TranslationPipeline {
        TranslationPipeline(
            provider: translationProvider,
            repository: SQLiteTranslationRepository(database: database)
        )
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

    private func cancelTasks() {
        frameTask?.cancel()
        segmentTask?.cancel()
        translationStateTask?.cancel()
        translationResultTask?.cancel()
        frameTask = nil
        segmentTask = nil
        translationStateTask = nil
        translationResultTask = nil
    }
}
