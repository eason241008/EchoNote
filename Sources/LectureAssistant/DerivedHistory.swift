import Foundation
import SQLite3

@MainActor
public extension SQLiteTranslationRepository {
    func history(sessionID: SessionID, sourceRevisionID: TranscriptRevisionID) throws -> [StoredTranslation] {
        try database.query("SELECT id, language_code, text, provider_id, model, state FROM translations WHERE session_id = ? AND source_revision_id = ? ORDER BY created_at", bindings: [.text(sessionID.rawValue.uuidString), .text(sourceRevisionID.rawValue.uuidString)]) { statement in
            StoredTranslation(id: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!, sessionID: sessionID, sourceRevisionID: sourceRevisionID, languageCode: String(cString: sqlite3_column_text(statement, 1)), text: String(cString: sqlite3_column_text(statement, 2)), providerID: String(cString: sqlite3_column_text(statement, 3)), model: String(cString: sqlite3_column_text(statement, 4)), state: DerivedContentState(rawValue: String(cString: sqlite3_column_text(statement, 5)))!)
        }
    }
}

@MainActor
public extension SQLiteNoteVersionRepository {
    func all(sessionID: SessionID) throws -> [StoredNoteVersion] {
        try database.query("SELECT id, version_number, content_json, provider_id, model, state FROM note_versions WHERE session_id = ? ORDER BY version_number", bindings: [.text(sessionID.rawValue.uuidString)]) { statement in
            StoredNoteVersion(id: UUID(uuidString: String(cString: sqlite3_column_text(statement, 0)))!, sessionID: sessionID, versionNumber: sqlite3_column_int64(statement, 1), contentJSON: String(cString: sqlite3_column_text(statement, 2)), providerID: String(cString: sqlite3_column_text(statement, 3)), model: String(cString: sqlite3_column_text(statement, 4)), state: DerivedContentState(rawValue: String(cString: sqlite3_column_text(statement, 5)))!)
        }
    }
}
