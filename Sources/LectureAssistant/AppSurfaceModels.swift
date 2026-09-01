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
    @Published public private(set) var isLoading = false
    @Published public var selectedSessionID: SessionID? {
        didSet { loadSelectedSnapshot() }
    }

    private let database: LectureDatabase
    private let sessionRoot: URL
    private let storage: SessionStorage
    private let exporter = LectureSnapshotExporter()
    private var hasLoaded = false

    public init(database: LectureDatabase, sessionRoot: URL) {
        self.database = database
        self.sessionRoot = sessionRoot
        storage = SessionStorage(rootURL: sessionRoot)
    }

    public var selectedSession: LibrarySessionSummary? {
        sessions.first { $0.id == selectedSessionID }
    }

    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        refresh()
    }

    public func refresh() {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try rebuildSearchIndex()
            try normalizeLegacySessionStates()
            sessions = try database.query(
                """
                SELECT s.id, s.title, s.state, s.created_at, s.updated_at,
                       (SELECT COUNT(*) FROM transcript_revisions tr WHERE tr.session_id = s.id),
                       (SELECT COUNT(*) FROM translations t WHERE t.session_id = s.id AND t.state = 'current')
                FROM lecture_sessions s
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
            hasLoaded = true
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
            WHERE tr.session_id = ?
              AND tr.revision_number = (
                  SELECT MAX(newer.revision_number)
                  FROM transcript_revisions newer
                  WHERE newer.session_id = tr.session_id
                    AND newer.segment_id = tr.segment_id
              )
            ORDER BY tr.starts_at
            """,
            bindings: [.text(sessionID.rawValue.uuidString)]
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
        try database.transaction {
            try database.execute(
                "DELETE FROM lecture_search WHERE content_type IN ('transcript', 'translation')"
            )
            try database.execute(
                """
                INSERT INTO lecture_search (
                    content_id, session_id, content_type, source_revision_id,
                    starts_at, ends_at, text
                )
                SELECT tr.segment_id, tr.session_id, 'transcript', tr.id,
                       tr.starts_at, tr.ends_at, tr.text
                FROM transcript_revisions tr
                WHERE tr.revision_number = (
                    SELECT MAX(newer.revision_number)
                    FROM transcript_revisions newer
                    WHERE newer.session_id = tr.session_id
                      AND newer.segment_id = tr.segment_id
                )
                """
            )
            try database.execute(
                """
                INSERT INTO lecture_search (
                    content_id, session_id, content_type, source_revision_id,
                    starts_at, ends_at, text
                )
                SELECT t.id, t.session_id, 'translation', t.source_revision_id,
                       tr.starts_at, tr.ends_at, t.text
                FROM translations t
                LEFT JOIN transcript_revisions tr ON tr.id = t.source_revision_id
                WHERE t.state = 'current'
                """
            )
        }
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
    @Published public private(set) var isRefreshing = false

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
        guard !isRefreshing else { return }
        isRefreshing = true
        let applicationSupportURL = applicationSupportURL
        let modelsRootURL = modelsRootURL
        Task { [weak self] in
            let statistics = await Task.detached(priority: .utility) {
                let installed = !SpeechModelManager.installedModelFolders(
                    modelsRootURL: modelsRootURL
                ).isEmpty
                return (
                    installed: installed,
                    modelSize: Self.directorySize(modelsRootURL),
                    storageSize: Self.directorySize(applicationSupportURL)
                )
            }.value
            guard let self else { return }
            self.modelInstalled = statistics.installed
            self.modelSize = statistics.modelSize
            self.storageSize = statistics.storageSize
            self.isRefreshing = false
        }
    }

    public func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([applicationSupportURL])
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
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
