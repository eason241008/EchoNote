import Foundation

public protocol CourseSchedulingService: Sendable {
    func courses() async -> [Course]
}

public struct LectureCapturePreparation: Sendable {
    public let session: LectureSession
    public let deviceID: UInt32

    public init(session: LectureSession, deviceID: UInt32) {
        self.session = session
        self.deviceID = deviceID
    }
}

public protocol LectureCaptureService: Sendable {
    func prepare(_ preparation: LectureCapturePreparation) async throws
    func start() async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
}

public protocol TranscriptionService: Sendable {
    func revisions(for sessionID: SessionID) async -> [TranscriptRevision]
}

public protocol TranslationService: Sendable {}
public protocol StudyNotesService: Sendable {}
public protocol LectureLibraryService: Sendable {}
public protocol LectureExportService: Sendable {}

public struct ApplicationServices: Sendable {
    public let scheduling: any CourseSchedulingService
    public let capture: any LectureCaptureService
    public let transcription: any TranscriptionService
    public let translation: any TranslationService
    public let studyNotes: any StudyNotesService
    public let library: any LectureLibraryService
    public let export: any LectureExportService

    public init(
        scheduling: any CourseSchedulingService,
        capture: any LectureCaptureService,
        transcription: any TranscriptionService,
        translation: any TranslationService,
        studyNotes: any StudyNotesService,
        library: any LectureLibraryService,
        export: any LectureExportService
    ) {
        self.scheduling = scheduling
        self.capture = capture
        self.transcription = transcription
        self.translation = translation
        self.studyNotes = studyNotes
        self.library = library
        self.export = export
    }
}

public struct EmptyCourseSchedulingService: CourseSchedulingService {
    public init() {}
    public func courses() async -> [Course] { [] }
}

public struct UnavailableLectureCaptureService: LectureCaptureService {
    public init() {}
    public func prepare(_ preparation: LectureCapturePreparation) async throws {}
    public func start() async throws {}
    public func pause() async throws {}
    public func resume() async throws {}
    public func stop() async throws {}
}

public struct EmptyTranscriptionService: TranscriptionService {
    public init() {}
    public func revisions(for sessionID: SessionID) async -> [TranscriptRevision] { [] }
}

public struct EmptyTranslationService: TranslationService { public init() {} }
public struct EmptyStudyNotesService: StudyNotesService { public init() {} }
public struct EmptyLectureLibraryService: LectureLibraryService { public init() {} }
public struct EmptyLectureExportService: LectureExportService { public init() {} }

public extension ApplicationServices {
    static let unavailable = ApplicationServices(
        scheduling: EmptyCourseSchedulingService(),
        capture: UnavailableLectureCaptureService(),
        transcription: EmptyTranscriptionService(),
        translation: EmptyTranslationService(),
        studyNotes: EmptyStudyNotesService(),
        library: EmptyLectureLibraryService(),
        export: EmptyLectureExportService()
    )
}
