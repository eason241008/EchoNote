import CryptoKit
import Foundation
import XCTest
@testable import LectureAssistant

final class SessionRecoveryTests: XCTestCase {
    func testRecoveryKeepsValidChunksAndReportsDamagedChunkGap() async throws {
        try await withStorage { storage, rootURL in
            let sessionID = SessionID()
            try await storage.createSession(
                manifest: SessionManifest(sessionID: sessionID, state: .interrupted)
            )
            let chunkID = try await storage.beginChunk(
                sessionID: sessionID,
                sequenceNumber: 0,
                startsAt: 0,
                externalWriter: true
            )
            let stagingURL = try await storage.activeChunkStagingURL(sessionID: sessionID, chunkID: chunkID)
            try Data("valid caf placeholder".utf8).write(to: stagingURL)
            _ = try await storage.finalizeChunk(sessionID: sessionID, chunkID: chunkID, endsAt: 2)
            let manifest = try await storage.loadManifest(sessionID: sessionID)
            let finalURL = rootURL
                .appendingPathComponent(sessionID.rawValue.uuidString)
                .appendingPathComponent(manifest.chunks[0].relativePath)
            try Data("damaged".utf8).write(to: finalURL)
            let partial = rootURL
                .appendingPathComponent(sessionID.rawValue.uuidString)
                .appendingPathComponent("chunks/.partial-abandoned.caf")
            FileManager.default.createFile(atPath: partial.path, contents: Data("partial".utf8))

            let coordinator = SessionRecoveryCoordinator(storage: storage, rootURL: rootURL)
            let report = try await coordinator.inspect(sessionID: sessionID)

            XCTAssertEqual(report.recoverableChunks, [])
            XCTAssertEqual(report.missingChunks.count, 1)
            XCTAssertEqual(report.orphanedPartials.map(\.lastPathComponent), [".partial-abandoned.caf"])
            XCTAssertEqual(report.gaps.count, 2)
            XCTAssertTrue(report.requiresUserDecision)
        }
    }

    func testAcceptRecoveryRemovesPartialsAndPreservesOnlyVerifiedChunks() async throws {
        try await withStorage { storage, rootURL in
            let sessionID = SessionID()
            try await storage.createSession(
                manifest: SessionManifest(sessionID: sessionID, state: .interrupted)
            )
            let chunkID = try await storage.beginChunk(
                sessionID: sessionID,
                sequenceNumber: 0,
                startsAt: 0,
                externalWriter: true
            )
            let stagingURL = try await storage.activeChunkStagingURL(sessionID: sessionID, chunkID: chunkID)
            let data = Data("valid".utf8)
            try data.write(to: stagingURL)
            _ = try await storage.finalizeChunk(sessionID: sessionID, chunkID: chunkID, endsAt: 1)
            let partial = rootURL
                .appendingPathComponent(sessionID.rawValue.uuidString)
                .appendingPathComponent("chunks/.partial-abandoned.caf")
            FileManager.default.createFile(atPath: partial.path, contents: Data("partial".utf8))

            let coordinator = SessionRecoveryCoordinator(storage: storage, rootURL: rootURL)
            let report = try await coordinator.acceptRecovery(sessionID: sessionID)

            XCTAssertEqual(report.missingChunks, [])
            XCTAssertEqual(report.recoverableChunks.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            let recoveredManifest = try await storage.loadManifest(sessionID: sessionID)
            XCTAssertEqual(recoveredManifest.state, .interrupted)
        }
    }

    func testRejectRecoveryDeletesSessionDirectory() async throws {
        try await withStorage { storage, rootURL in
            let sessionID = SessionID()
            try await storage.createSession(
                manifest: SessionManifest(sessionID: sessionID, state: .interrupted)
            )
            let coordinator = SessionRecoveryCoordinator(storage: storage, rootURL: rootURL)
            try await coordinator.rejectRecovery(sessionID: sessionID)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: rootURL.appendingPathComponent(sessionID.rawValue.uuidString).path
                )
            )
        }
    }

    private func withStorage(
        _ operation: (SessionStorage, URL) async throws -> Void
    ) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await operation(SessionStorage(rootURL: rootURL), rootURL)
    }
}
