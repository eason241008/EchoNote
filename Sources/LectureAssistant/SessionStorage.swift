import CryptoKit
import Foundation

public struct AudioChunkManifest: Codable, Equatable, Sendable {
    public let id: UUID
    public let sequenceNumber: Int64
    public let relativePath: String
    public let startsAt: TimeInterval
    public let endsAt: TimeInterval
    public let byteCount: Int64
    public let sha256: String
    public let finalizedAt: Date

    public init(
        id: UUID,
        sequenceNumber: Int64,
        relativePath: String,
        startsAt: TimeInterval,
        endsAt: TimeInterval,
        byteCount: Int64,
        sha256: String,
        finalizedAt: Date
    ) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.relativePath = relativePath
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.byteCount = byteCount
        self.sha256 = sha256
        self.finalizedAt = finalizedAt
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public let sessionID: SessionID
    public var state: SessionState
    public var selectedDeviceID: String?
    public var courseID: CourseID?
    public var transcriptionModel: String?
    public var lastCommittedChunk: Int64?
    public var chunks: [AudioChunkManifest]
    public var updatedAt: Date

    public init(
        version: Int = currentVersion,
        sessionID: SessionID,
        state: SessionState,
        selectedDeviceID: String? = nil,
        courseID: CourseID? = nil,
        transcriptionModel: String? = nil,
        lastCommittedChunk: Int64? = nil,
        chunks: [AudioChunkManifest] = [],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.sessionID = sessionID
        self.state = state
        self.selectedDeviceID = selectedDeviceID
        self.courseID = courseID
        self.transcriptionModel = transcriptionModel
        self.lastCommittedChunk = lastCommittedChunk
        self.chunks = chunks
        self.updatedAt = updatedAt
    }
}

public enum SessionStorageError: LocalizedError, Equatable {
    case invalidSequence
    case chunkAlreadyActive
    case noActiveChunk
    case activeChunkMismatch
    case invalidChunkTimeRange
    case manifestMismatch
    case unsupportedManifestVersion(Int)
    case fileOperationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSequence:
            return "Audio chunk sequence numbers must increase monotonically."
        case .chunkAlreadyActive:
            return "An audio chunk is already being written."
        case .noActiveChunk:
            return "No audio chunk is currently being written."
        case .activeChunkMismatch:
            return "The active audio chunk does not match the requested chunk."
        case .invalidChunkTimeRange:
            return "The audio chunk end time precedes its start time."
        case .manifestMismatch:
            return "The session manifest does not match its storage directory."
        case let .unsupportedManifestVersion(version):
            return "Session manifest version \(version) is not supported."
        case .fileOperationFailed:
            return "The lecture session data could not be stored safely."
        }
    }
}

public struct SessionDirectoryLayout: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func sessionURL(for sessionID: SessionID) -> URL {
        rootURL.appendingPathComponent(sessionID.rawValue.uuidString, isDirectory: true)
    }

    public func chunksURL(for sessionID: SessionID) -> URL {
        sessionURL(for: sessionID).appendingPathComponent("chunks", isDirectory: true)
    }

    public func manifestURL(for sessionID: SessionID) -> URL {
        sessionURL(for: sessionID).appendingPathComponent("manifest.json", isDirectory: false)
    }
}

private struct ActiveChunk {
    let id: UUID
    let sequenceNumber: Int64
    let startsAt: TimeInterval
    let stagingURL: URL
    let finalURL: URL
    let relativePath: String
    let handle: FileHandle?
    var byteCount: Int64
    var hasher: SHA256
}

public actor SessionStorage {
    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SessionStorageError.fileOperationFailed
        }
        return applicationSupport
            .appendingPathComponent("LectureAssistant", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    private let fileManager: FileManager
    private let layout: SessionDirectoryLayout
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var activeChunks: [SessionID: ActiveChunk] = [:]

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        layout = SessionDirectoryLayout(rootURL: rootURL)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    public func createSession(manifest: SessionManifest) throws {
        try validate(manifest)
        let sessionURL = layout.sessionURL(for: manifest.sessionID)
        let chunksURL = layout.chunksURL(for: manifest.sessionID)
        do {
            try fileManager.createDirectory(at: chunksURL, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: layout.manifestURL(for: manifest.sessionID).path) {
                try persist(manifest: manifest)
            }
        } catch let error as SessionStorageError {
            throw error
        } catch {
            try? fileManager.removeItem(at: sessionURL)
            throw SessionStorageError.fileOperationFailed
        }
    }

    public func loadManifest(sessionID: SessionID) throws -> SessionManifest {
        do {
            let data = try Data(contentsOf: layout.manifestURL(for: sessionID))
            let manifest = try decoder.decode(SessionManifest.self, from: data)
            try validate(manifest)
            guard manifest.sessionID == sessionID else {
                throw SessionStorageError.manifestMismatch
            }
            return manifest
        } catch let error as SessionStorageError {
            throw error
        } catch {
            throw SessionStorageError.fileOperationFailed
        }
    }

    public func persist(manifest: SessionManifest) throws {
        try validate(manifest)
        let sessionURL = layout.sessionURL(for: manifest.sessionID)
        let manifestURL = layout.manifestURL(for: manifest.sessionID)
        let stagingURL = sessionURL.appendingPathComponent(".manifest-\(UUID().uuidString).tmp")
        do {
            try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
            let data = try encoder.encode(manifest)
            try data.write(to: stagingURL, options: [.atomic])
            try replaceItem(at: manifestURL, with: stagingURL)
        } catch let error as SessionStorageError {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw SessionStorageError.fileOperationFailed
        }
    }

    @discardableResult
    public func beginChunk(
        sessionID: SessionID,
        sequenceNumber: Int64,
        startsAt: TimeInterval,
        externalWriter: Bool = false
    ) throws -> UUID {
        guard activeChunks[sessionID] == nil else {
            throw SessionStorageError.chunkAlreadyActive
        }
        var manifest = try loadManifest(sessionID: sessionID)
        let expectedSequence = (manifest.lastCommittedChunk ?? -1) + 1
        guard sequenceNumber == expectedSequence else {
            throw SessionStorageError.invalidSequence
        }

        let chunkID = UUID()
        let filename = String(format: "%08lld-%@.caf", sequenceNumber, chunkID.uuidString)
        let chunksURL = layout.chunksURL(for: sessionID)
        let finalURL = chunksURL.appendingPathComponent(filename)
        let stagingURL = chunksURL.appendingPathComponent(".partial-\(filename)")
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw SessionStorageError.fileOperationFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: stagingURL)
            if externalWriter {
                try handle.close()
            }
            activeChunks[sessionID] = ActiveChunk(
                id: chunkID,
                sequenceNumber: sequenceNumber,
                startsAt: startsAt,
                stagingURL: stagingURL,
                finalURL: finalURL,
                relativePath: "chunks/\(filename)",
                handle: externalWriter ? nil : handle,
                byteCount: 0,
                hasher: SHA256()
            )
            manifest.updatedAt = Date()
            try persist(manifest: manifest)
            return chunkID
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw SessionStorageError.fileOperationFailed
        }
    }

    public func append(_ data: Data, sessionID: SessionID, chunkID: UUID) throws {
        guard var chunk = activeChunks[sessionID] else {
            throw SessionStorageError.noActiveChunk
        }
        guard chunk.id == chunkID else {
            throw SessionStorageError.activeChunkMismatch
        }
        guard let handle = chunk.handle else {
            throw SessionStorageError.fileOperationFailed
        }
        do {
            try handle.write(contentsOf: data)
            chunk.byteCount += Int64(data.count)
            chunk.hasher.update(data: data)
            activeChunks[sessionID] = chunk
        } catch {
            throw SessionStorageError.fileOperationFailed
        }
    }

    public func activeChunkStagingURL(sessionID: SessionID, chunkID: UUID) throws -> URL {
        guard let chunk = activeChunks[sessionID] else {
            throw SessionStorageError.noActiveChunk
        }
        guard chunk.id == chunkID else {
            throw SessionStorageError.activeChunkMismatch
        }
        return chunk.stagingURL
    }

    @discardableResult
    public func finalizeChunk(
        sessionID: SessionID,
        chunkID: UUID,
        endsAt: TimeInterval
    ) throws -> AudioChunkManifest {
        guard let chunk = activeChunks[sessionID] else {
            throw SessionStorageError.noActiveChunk
        }
        guard chunk.id == chunkID else {
            throw SessionStorageError.activeChunkMismatch
        }
        guard endsAt >= chunk.startsAt else {
            throw SessionStorageError.invalidChunkTimeRange
        }

        do {
            try chunk.handle?.synchronize()
            try chunk.handle?.close()
            let fileAttributes = try fileManager.attributesOfItem(atPath: chunk.stagingURL.path)
            let byteCount = (fileAttributes[.size] as? NSNumber)?.int64Value ?? chunk.byteCount
            let digest: String
            if chunk.handle == nil {
                digest = try sha256(of: chunk.stagingURL)
            } else {
                digest = chunk.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            try fileManager.moveItem(at: chunk.stagingURL, to: chunk.finalURL)
            let finalized = AudioChunkManifest(
                id: chunk.id,
                sequenceNumber: chunk.sequenceNumber,
                relativePath: chunk.relativePath,
                startsAt: chunk.startsAt,
                endsAt: endsAt,
                byteCount: byteCount,
                sha256: digest,
                finalizedAt: Date()
            )
            var manifest = try loadManifest(sessionID: sessionID)
            manifest.chunks.append(finalized)
            manifest.chunks.sort { $0.sequenceNumber < $1.sequenceNumber }
            manifest.lastCommittedChunk = finalized.sequenceNumber
            manifest.updatedAt = Date()
            try persist(manifest: manifest)
            activeChunks.removeValue(forKey: sessionID)
            return finalized
        } catch let error as SessionStorageError {
            throw error
        } catch {
            throw SessionStorageError.fileOperationFailed
        }
    }

    public func abandonActiveChunk(sessionID: SessionID) {
        guard let chunk = activeChunks.removeValue(forKey: sessionID) else { return }
        try? chunk.handle?.close()
        try? fileManager.removeItem(at: chunk.stagingURL)
    }

    public func finalizedChunkURL(
        sessionID: SessionID,
        chunk: AudioChunkManifest
    ) throws -> URL {
        let sessionURL = layout.sessionURL(for: sessionID).standardizedFileURL
        let candidate = sessionURL.appendingPathComponent(chunk.relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(sessionURL.path + "/") else {
            throw SessionStorageError.manifestMismatch
        }
        return candidate
    }

    private func validate(_ manifest: SessionManifest) throws {
        guard manifest.version == SessionManifest.currentVersion else {
            throw SessionStorageError.unsupportedManifestVersion(manifest.version)
        }
        let sequences = manifest.chunks.map(\.sequenceNumber)
        guard sequences == sequences.sorted(), Set(sequences).count == sequences.count else {
            throw SessionStorageError.manifestMismatch
        }
        guard manifest.lastCommittedChunk == sequences.last else {
            throw SessionStorageError.manifestMismatch
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

    private func replaceItem(at destinationURL: URL, with stagingURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }
}
