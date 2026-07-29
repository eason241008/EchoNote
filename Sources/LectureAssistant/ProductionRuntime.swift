import Foundation

@MainActor
public final class ProductionRuntime: ObservableObject {
    public let applicationModel: ApplicationModel
    public let captionWorkspace: CaptionWorkspaceModel
    public let timetable: TimetableStore
    public let library: LectureLibraryModel
    public let settings: RuntimeSettingsModel
    public let speechModel: SpeechModelManager
    public let translationProvider: AppleTranslationProvider
    public let modelsRootURL: URL
    public let applicationSupportURL: URL
    public init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) throws {
        let libraryURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let baseURL = libraryURL.appendingPathComponent("EchoNote", isDirectory: true)
        let legacyURL = libraryURL.appendingPathComponent("课堂伴侣", isDirectory: true)
        if !fileManager.fileExists(atPath: baseURL.path),
           fileManager.fileExists(atPath: legacyURL.path) {
            try fileManager.moveItem(at: legacyURL, to: baseURL)
        }
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        applicationSupportURL = baseURL

        let database = try LectureDatabase(url: baseURL.appendingPathComponent("lectures.sqlite"))
        try database.migrate()
        let sessionsURL = baseURL.appendingPathComponent("Sessions", isDirectory: true)
        let modelsURL = baseURL.appendingPathComponent("Models", isDirectory: true)
        modelsRootURL = modelsURL
        let speechModelManager = SpeechModelManager(modelsRootURL: modelsURL)
        let translationProvider = AppleTranslationProvider()
        speechModel = speechModelManager
        self.translationProvider = translationProvider

        let captionWorkspace = CaptionWorkspaceModel(defaults: defaults)
        let timetable = TimetableStore(defaults: defaults)
        self.captionWorkspace = captionWorkspace
        self.timetable = timetable
        library = LectureLibraryModel(database: database, sessionRoot: sessionsURL)
        settings = RuntimeSettingsModel(
            applicationSupportURL: baseURL,
            modelsRootURL: modelsURL,
            timetable: timetable,
            defaults: defaults
        )

        let storage = SessionStorage(rootURL: sessionsURL)
        let modelFolder = modelsURL.appendingPathComponent(
            "openai_whisper-\(SpeechModelDescriptor.smallEnglish.id)",
            isDirectory: true
        )
        let capture = ProductionLectureCaptureService(
            storage: storage,
            database: database,
            modelFolder: modelFolder,
            captionWorkspace: captionWorkspace,
            translationProvider: translationProvider
        )
        let services = ApplicationServices(
            scheduling: EmptyCourseSchedulingService(),
            capture: capture,
            transcription: EmptyTranscriptionService(),
            translation: EmptyTranslationService(),
            studyNotes: EmptyStudyNotesService(),
            library: EmptyLectureLibraryService(),
            export: EmptyLectureExportService()
        )
        applicationModel = ApplicationModel(
            services: services,
            defaults: defaults,
            preflightService: CapturePreflightService(),
            storageRootURL: sessionsURL,
            transcriptionModelReady: {
                speechModelManager.isReady
            }
        )
    }

}
