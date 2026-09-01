import Foundation
import XCTest
@testable import LectureAssistant

@MainActor
final class AppSurfaceModelsTests: XCTestCase {
    func testLibraryLoadsProductionSessionAndSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try LectureDatabase(url: root.appendingPathComponent("lectures.sqlite"))
        try database.migrate()
        let session = LectureSession(title: "Machine Learning", state: .completed)
        try SQLiteLectureSessionRepository(database: database).save(session)
        let revision = try SQLiteTranscriptRevisionRepository(database: database).createRevision(
            sessionID: session.id,
            segmentID: "segment-0",
            startsAt: 0,
            endsAt: 2,
            text: "The lecture explains models.",
            status: .finalized
        )
        _ = try SQLiteTranslationRepository(database: database).save(
            sessionID: session.id,
            sourceRevisionID: revision.id,
            languageCode: "zh-Hans",
            text: "本讲座介绍模型。",
            providerID: "test",
            model: "test-model"
        )

        let model = LectureLibraryModel(database: database, sessionRoot: root.appendingPathComponent("Sessions"))
        model.loadIfNeeded()

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].transcriptCount, 1)
        XCTAssertEqual(model.sessions[0].translationCount, 1)
        XCTAssertEqual(model.selectedSnapshot?.segments.map(\.text), ["The lecture explains models."])
        XCTAssertEqual(model.selectedSnapshot?.translations.map(\.text), ["本讲座介绍模型。"])
    }

    func testLibraryNormalizesOnlyPreparedSessionsWithTranscriptData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-normalize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try LectureDatabase(url: root.appendingPathComponent("lectures.sqlite"))
        try database.migrate()
        let empty = LectureSession(title: "Empty prepared")
        let legacy = LectureSession(title: "Legacy prepared")
        try SQLiteLectureSessionRepository(database: database).save(empty)
        try SQLiteLectureSessionRepository(database: database).save(legacy)
        _ = try SQLiteTranscriptRevisionRepository(database: database).createRevision(
            sessionID: legacy.id,
            segmentID: "segment-0",
            startsAt: 0,
            endsAt: 1,
            text: "Recorded",
            status: .finalized
        )

        let model = LectureLibraryModel(database: database, sessionRoot: root.appendingPathComponent("Sessions"))
        model.loadIfNeeded()
        let states = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.title, $0.state) })
        XCTAssertEqual(states["Empty prepared"], .prepared)
        XCTAssertEqual(states["Legacy prepared"], .completed)
    }

    func testRuntimeSettingsPersistsBoundedRetention() throws {
        let suiteName = #function
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let timetable = TimetableStore(defaults: defaults)
        let model = RuntimeSettingsModel(
            applicationSupportURL: root,
            modelsRootURL: root.appendingPathComponent("Models"),
            timetable: timetable,
            defaults: defaults
        )
        model.setRetentionDays(400)
        XCTAssertEqual(model.retentionDays, 365)

        let restored = RuntimeSettingsModel(
            applicationSupportURL: root,
            modelsRootURL: root.appendingPathComponent("Models"),
            timetable: timetable,
            defaults: defaults
        )
        XCTAssertEqual(restored.retentionDays, 365)
    }
}
