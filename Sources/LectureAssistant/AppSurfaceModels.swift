import AppKit
import Foundation
import SQLite3

public struct LibrarySessionSummary: Identifiable, Equatable {
    public let id: SessionID
    public let title: String
    public let state: SessionState
    public let createdAt: Date
    public let updatedAt: Date
    public let transcriptCount: Int
    public let translationCount: Int
}

@MainActor
public final class LectureLibraryModel: ObservableObject {
    @Published public private(set) var sessions: [LibrarySessionSummary] = []
    @Published public private(set) var searchResults: [LectureSearchResult] = []
    @Published public private(set) var selectedSnapshot: LectureSnapshot?
    @Published public private(set) var selectedPostClassTranscripts: [PostClassTranscriptDocument] = []
    @Published public private(set) var statusMessage: String?
    @Published public var selectedSessionID: SessionID? {
        didSet { loadSelectedSnapshot() }
    }

    private let database: LectureDatabase
    private let sessionRoot: URL
    private let storage: SessionStorage
    private let exporter = LectureSnapshotExporter()

    public init(database: LectureDatabase, sessionRoot: URL) {
        self.database = database
        self.sessionRoot = sessionRoot
        storage = SessionStorage(rootURL: sessionRoot)
        refresh()
    }

    public var selectedSession: LibrarySessionSummary? {
        sessions.first { $0.id == selectedSessionID }
    }

    public func refresh() {
        do {
            try rebuildSearchIndex()
            try normalizeLegacySessionStates()
            sessions = try database.query(
                """
                SELECT s.id, s.title, s.state, s.created_at, s.updated_at,
                       COUNT(DISTINCT tr.id), COUNT(DISTINCT t.id)
                FROM lecture_sessions s
                LEFT JOIN transcript_revisions tr ON tr.session_id = s.id
                LEFT JOIN translations t ON t.session_id = s.id AND t.state = 'current'
                GROUP BY s.id
                ORDER BY s.updated_at DESC
                """,
                bindings: []
            ) { statement in
                LibrarySessionSummary(
                    id: SessionID(rawValue: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!),
                    title: String(cString: sqlite3_column_text(statement, 1)),
                    state: SessionState(rawValue: String(cString: sqlite3_column_text(statement, 2))) ?? .interrupted,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    transcriptCount: Int(sqlite3_column_int64(statement, 5)),
                    translationCount: Int(sqlite3_column_int64(statement, 6))
                )
            }
            if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
                selectedSessionID = sessions.first?.id
            } else {
                loadSelectedSnapshot()
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func search(_ query: String) {
        do {
            searchResults = try SQLiteLectureSearchRepository(database: database).search(query)
            statusMessage = searchResults.isEmpty && !query.isEmpty ? "没有找到匹配内容。" : nil
        } catch {
            searchResults = []
            statusMessage = error.localizedDescription
        }
    }

    public func selectSearchResult(_ result: LectureSearchResult) {
        selectedSessionID = result.sessionID
    }

    public func deleteSelectedSession() {
        guard let selectedSessionID else { return }
        do {
            let report = try SessionDeletionCoordinator(
                database: database,
                sessionRoot: sessionRoot
            ).delete(sessionID: selectedSessionID)
            self.selectedSessionID = nil
            refresh()
            statusMessage = report.deletedSession ? "课堂记录已删除。" : "部分文件无法删除，可稍后重试。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func exportSelected(as format: LibraryExportFormat) {
        guard let selectedSnapshot else { return }
        do {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(safeFilename(selectedSnapshot.title)).\(format.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let data: Data
            switch format {
            case .markdown: data = Data(exporter.markdown(selectedSnapshot).utf8)
            case .srt: data = Data(exporter.srt(selectedSnapshot).utf8)
            case .json: data = try exporter.json(selectedSnapshot)
            case .pdf: data = exporter.pdf(selectedSnapshot)
            }
            try data.write(to: url, options: .atomic)
            statusMessage = "已导出到 \(url.lastPathComponent)。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func snapshot(sessionID: SessionID) throws -> LectureSnapshot {
        let session = try SQLiteLectureSessionRepository(database: database).session(id: sessionID)
        let segmentRows = try database.query(
            """
            SELECT tr.segment_id, tr.id, tr.starts_at, tr.ends_at, tr.text, tr.status
            FROM transcript_revisions tr
            JOIN (
                SELECT segment_id, MAX(revision_number) AS revision_number
                FROM transcript_revisions WHERE session_id = ? GROUP BY segment_id
            ) current ON current.segment_id = tr.segment_id AND current.revision_number = tr.revision_number
            WHERE tr.session_id = ? ORDER BY tr.starts_at
            """,
            bindings: [.text(sessionID.rawValue.uuidString), .text(sessionID.rawValue.uuidString)]
        ) { statement in
            LectureSnapshot.Segment(
                id: String(cString: sqlite3_column_text(statement, 0)),
                start: sqlite3_column_double(statement, 2),
                end: sqlite3_column_double(statement, 3),
                text: String(cString: sqlite3_column_text(statement, 4)),
                isGap: String(cString: sqlite3_column_text(statement, 5)) == TranscriptRevisionStatus.gap.rawValue
            )
        }
        let translations = try database.query(
            "SELECT source_revision_id, language_code, text FROM translations WHERE session_id = ? AND state = 'current' ORDER BY created_at",
            bindings: [.text(sessionID.rawValue.uuidString)]
        ) { statement in
            LectureSnapshot.Translation(
                sourceRevisionID: TranscriptRevisionID(rawValue: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!),
                languageCode: String(cString: sqlite3_column_text(statement, 1)),
                text: String(cString: sqlite3_column_text(statement, 2))
            )
        }
        return LectureSnapshot(
            sessionID: sessionID,
            title: session?.title ?? "课堂记录",
            segments: segmentRows,
            translations: translations,
            bookmarks: try SQLiteBookmarkRepository(database: database).all(sessionID: sessionID)
        )
    }

    private func normalizeLegacySessionStates() throws {
        try database.execute(
            """
            UPDATE lecture_sessions
            SET state = 'completed', updated_at = COALESCE(
                (SELECT MAX(created_at) FROM transcript_revisions WHERE session_id = lecture_sessions.id),
                updated_at
            )
            WHERE state = 'prepared'
              AND EXISTS (
                SELECT 1 FROM transcript_revisions WHERE session_id = lecture_sessions.id
              )
            """
        )
    }

    private func rebuildSearchIndex() throws {
        let search = SQLiteLectureSearchRepository(database: database)
        let transcriptRows = try database.query(
            """
            SELECT session_id, segment_id
            FROM transcript_revisions
            GROUP BY session_id, segment_id
            """,
            bindings: []
        ) { statement in
            (
                sessionID: SessionID(rawValue: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!),
                segmentID: String(cString: sqlite3_column_text(statement, 1))
            )
        }
        for row in transcriptRows {
            try search.indexCurrentTranscript(sessionID: row.sessionID, segmentID: row.segmentID)
        }
        let translationIDs = try database.query(
            "SELECT id FROM translations WHERE state = 'current'",
            bindings: []
        ) { statement in
            UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!
        }
        for id in translationIDs { try search.indexTranslation(id: id) }
    }

    private func loadSelectedSnapshot() {
        guard let selectedSessionID else {
            selectedSnapshot = nil
            selectedPostClassTranscripts = []
            return
        }
        selectedSnapshot = try? snapshot(sessionID: selectedSessionID)
        selectedPostClassTranscripts = []
        Task { [weak self, storage] in
            let documents = (try? await storage.postClassTranscripts(
                sessionID: selectedSessionID
            )) ?? []
            guard self?.selectedSessionID == selectedSessionID else { return }
            self?.selectedPostClassTranscripts = documents
        }
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

public enum LibraryExportFormat: String, CaseIterable, Identifiable {
    case markdown, srt, json, pdf
    public var id: String { rawValue }
    public var fileExtension: String { rawValue == "markdown" ? "md" : rawValue }
    public var title: String { rawValue.uppercased() }
}

@MainActor
public final class RuntimeSettingsModel: ObservableObject {
    @Published public private(set) var modelInstalled = false
    @Published public private(set) var modelSize: Int64 = 0
    @Published public private(set) var storageSize: Int64 = 0
    @Published public private(set) var retentionDays: Int

    public let applicationSupportURL: URL
    public let modelsRootURL: URL
    public var timetableURL: URL? { timetable.subscriptionURL }
    private let defaults: UserDefaults
    private let retentionKey = "lecture-assistant.retention-days"
    private let timetable: TimetableStore

    public init(
        applicationSupportURL: URL,
        modelsRootURL: URL,
        timetable: TimetableStore,
        defaults: UserDefaults = .standard
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.modelsRootURL = modelsRootURL
        self.timetable = timetable
        self.defaults = defaults
        retentionDays = defaults.object(forKey: retentionKey) == nil ? 30 : defaults.integer(forKey: retentionKey)
        refresh()
    }

    public func setRetentionDays(_ days: Int) {
        retentionDays = min(365, max(0, days))
        defaults.set(retentionDays, forKey: retentionKey)
    }

    public func setTimetableURL(_ value: String) async {
        do {
            try timetable.setSubscriptionURL(value)
            await timetable.refresh()
        } catch {}
        objectWillChange.send()
    }

    public func refresh() {
        modelInstalled = !SpeechModelManager.installedModelFolders(
            modelsRootURL: modelsRootURL
        ).isEmpty
        modelSize = directorySize(modelsRootURL)
        storageSize = directorySize(applicationSupportURL)
    }

    public func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([applicationSupportURL])
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap { url in
            (url as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        }
            .reduce(0) { $0 + Int64($1) }
    }
}
