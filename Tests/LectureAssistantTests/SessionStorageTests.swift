import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import LectureAssistant

final class SessionStorageTests: XCTestCase {
    func testFinalizesChunkAndPersistsReloadableManifest() async throws {
        try await withStorage { storage, rootURL in
            let sessionID = SessionID()
            try await storage.createSession(
                manifest: SessionManifest(sessionID: sessionID, state: .recording)
            )
            let chunkID = try await storage.beginChunk(
                sessionID: sessionID,
                sequenceNumber: 0,
                startsAt: 1.25
            )
            let first = Data("lecture ".utf8)
            let second = Data("audio".utf8)
            try await storage.append(first, sessionID: sessionID, chunkID: chunkID)
            try await storage.append(second, sessionID: sessionID, chunkID: chunkID)

            let finalized = try await storage.finalizeChunk(
                sessionID: sessionID,
                chunkID: chunkID,
                endsAt: 3.5
            )
            let manifest = try await storage.loadManifest(sessionID: sessionID)
            let chunkURL = try await storage.finalizedChunkURL(
                sessionID: sessionID,
                chunk: finalized
            )

            XCTAssertEqual(manifest.lastCommittedChunk, 0)
            let persistedChunk = try XCTUnwrap(manifest.chunks.first)
            XCTAssertEqual(manifest.chunks.count, 1)
            XCTAssertEqual(persistedChunk.id, finalized.id)
            XCTAssertEqual(persistedChunk.sequenceNumber, finalized.sequenceNumber)
            XCTAssertEqual(persistedChunk.relativePath, finalized.relativePath)
            XCTAssertEqual(persistedChunk.startsAt, finalized.startsAt)
            XCTAssertEqual(persistedChunk.endsAt, finalized.endsAt)
            XCTAssertEqual(persistedChunk.byteCount, finalized.byteCount)
            XCTAssertEqual(persistedChunk.sha256, finalized.sha256)
            XCTAssertEqual(persistedChunk.finalizedAt.timeIntervalSince1970, finalized.finalizedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(finalized.byteCount, Int64(first.count + second.count))
            XCTAssertEqual(finalized.sha256, SHA256.hash(data: first + second).hexString)
            XCTAssertEqual(try Data(contentsOf: chunkURL), first + second)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(
                    at: rootURL.appendingPathComponent(sessionID.rawValue.uuidString).appendingPathComponent("chunks"),
                    includingPropertiesForKeys: nil
                ).contains { $0.pathExtension == "part" }
            )
        }
    }

    func testExternalCAFWriterIsAtomicallyFinalizedAndHashed() async throws {
        try await withStorage { storage, _ in
            let sessionID = SessionID()
            try await storage.createSession(
                manifest: SessionManifest(sessionID: sessionID, state: .recording)
            )
            let chunkID = try await storage.beginChunk(
                sessionID: sessionID,
                sequenceNumber: 0,
                startsAt: 0,
                externalWriter: true
            )
            let stagingURL = try await storage.activeChunkStagingURL(
                sessionID: sessionID,
                chunkID: chunkID
            )
            let format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                )
            )
            let file = try AVAudioFile(forWriting: stagingURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            buffer.frameLength = 4
            buffer.floatChannelData?[0][0] = 0.25
            buffer.floatChannelData?[0][1] = -0.25
            buffer.floatChannelData?[0][2] = 0.5
            buffer.floatChannelData?[0][3] = -0.5
            try file.write(from: buffer)

            let finalized = try await storage.finalizeChunk(
                sessionID: sessionID,
                chunkID: chunkID,
                endsAt: 0.001
            )
            let finalURL = try await storage.finalizedChunkURL(
                sessionID: sessionID,
                chunk: finalized
            )
            let reopened = try AVAudioFile(forReading: finalURL)

            XCTAssertGreaterThan(finalized.byteCount, 0)
            XCTAssertEqual(finalized.sha256, SHA256.hash(data: try Data(contentsOf: finalURL)).hexString)
            XCTAssertEqual(reopened.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(reopened.length, 4)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        }
    }

    func testAbandonedChunkNeverAppearsCommitted() async throws {
        try await withStorage { storage, _ in
            let sessionID = SessionID()
            try await storage.createSession(
                manifest: SessionManifest(sessionID: sessionID, state: .recording)
            )
            let chunkID = try await storage.beginChunk(
                sessionID: sessionID,
                sequenceNumber: 0,
                startsAt: 0
            )
            try await storage.append(Data("partial".utf8), sessionID: sessionID, chunkID: chunkID)
            await storage.abandonActiveChunk(sessionID: sessionID)

            let manifest = try await storage.loadManifest(sessionID: sessionID)
            XCTAssertNil(manifest.lastCommittedChunk)
            XCTAssertEqual(manifest.chunks, [])
        }
    }

    func testRejectsNonMonotonicChunkSequence() async throws {
        try await withStorage { storage, _ in
            let sessionID = SessionID()
            try await storage.createSession(
                manifest: SessionManifest(sessionID: sessionID, state: .recording)
            )

            do {
                _ = try await storage.beginChunk(
                    sessionID: sessionID,
                    sequenceNumber: 1,
                    startsAt: 0
                )
                XCTFail("Expected invalid sequence")
            } catch {
                XCTAssertEqual(error as? SessionStorageError, .invalidSequence)
            }
        }
    }

    private func withStorage(
        _ operation: (SessionStorage, URL) async throws -> Void
    ) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lecture-session-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await operation(SessionStorage(rootURL: rootURL), rootURL)
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
