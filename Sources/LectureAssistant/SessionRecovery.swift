import CryptoKit
import Foundation

public struct SessionRecoveryGap: Equatable, Sendable {
    public let sequenceNumber: Int64
    public let startsAt: TimeInterval?
    public let endsAt: TimeInterval?
    public let reason: String
}

public struct SessionRecoveryReport: Equatable, Sendable {
    public let sessionID: SessionID
    public let manifest: SessionManifest
    public let recoverableChunks: [AudioChunkManifest]
    public let missingChunks: [AudioChunkManifest]
    public let orphanedPartials: [URL]
    public let gaps: [SessionRecoveryGap]

    public var requiresUserDecision: Bool {
        !missingChunks.isEmpty || !orphanedPartials.isEmpty || manifest.state == .interrupted
    }
}

public enum SessionRecoveryError: LocalizedError, Equatable {
    case sessionNotFound
    case corruptedChunk(AudioChunkManifest)
    case deletionFailed

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound: return "The interrupted lecture session could not be found."
        case .corruptedChunk: return "A finalized lecture chunk failed integrity verification."
        case .deletionFailed: return "The interrupted lecture session could not be deleted."
        }
    }
}

public actor SessionRecoveryCoordinator {
    private let storage: SessionStorage
    private let rootURL: URL
    private let fileManager: FileManager

    public init(
        storage: SessionStorage,
        rootURL: URL,
        fileManager: FileManager = .default
    ) {
        self.storage = storage
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func inspect(sessionID: SessionID) async throws -> SessionRecoveryReport {
        let manifest = try await storage.loadManifest(sessionID: sessionID)
        let sessionURL = rootURL.appendingPathComponent(sessionID.rawValue.uuidString)
        let chunksURL = sessionURL.appendingPathComponent("chunks")
        var recoverable: [AudioChunkManifest] = []
        var missing: [AudioChunkManifest] = []
        var gaps: [SessionRecoveryGap] = []

        for chunk in manifest.chunks.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            let url = sessionURL.appendingPathComponent(chunk.relativePath)
            guard fileManager.fileExists(atPath: url.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size == chunk.byteCount,
                  (try? sha256(of: url)) == chunk.sha256 else {
                missing.append(chunk)
                gaps.append(SessionRecoveryGap(
                    sequenceNumber: chunk.sequenceNumber,
                    startsAt: chunk.startsAt,
                    endsAt: chunk.endsAt,
                    reason: "Finalized chunk is missing or failed integrity verification."
                ))
                continue
            }
            recoverable.append(chunk)
        }

        let partials = (try? fileManager.contentsOfDirectory(
            at: chunksURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".partial-") }) ?? []
        if !partials.isEmpty {
            gaps.append(SessionRecoveryGap(
                sequenceNumber: (manifest.lastCommittedChunk ?? -1) + 1,
                startsAt: manifest.chunks.last?.endsAt,
                endsAt: nil,
                reason: "An unfinished chunk was found and is not treated as recorded audio."
            ))
        }
        return SessionRecoveryReport(
            sessionID: sessionID,
            manifest: manifest,
            recoverableChunks: recoverable,
            missingChunks: missing,
            orphanedPartials: partials,
            gaps: gaps
        )
    }

    public func acceptRecovery(sessionID: SessionID) async throws -> SessionRecoveryReport {
        let report = try await inspect(sessionID: sessionID)
        var manifest = report.manifest
        manifest.chunks = report.recoverableChunks
        manifest.lastCommittedChunk = report.recoverableChunks.last?.sequenceNumber
        manifest.state = .interrupted
        manifest.updatedAt = Date()
        try await storage.persist(manifest: manifest)
        for partial in report.orphanedPartials {
            try? fileManager.removeItem(at: partial)
        }
        return try await inspect(sessionID: sessionID)
    }

    public func rejectRecovery(sessionID: SessionID) throws {
        let sessionURL = rootURL.appendingPathComponent(sessionID.rawValue.uuidString)
        guard fileManager.fileExists(atPath: sessionURL.path) else {
            throw SessionRecoveryError.sessionNotFound
        }
        do {
            try fileManager.removeItem(at: sessionURL)
        } catch {
            throw SessionRecoveryError.deletionFailed
        }
    }


    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
