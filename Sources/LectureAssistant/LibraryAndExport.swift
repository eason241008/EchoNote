import AppKit
import Foundation

public enum RawAudioRetentionPolicy: Equatable, Sendable {
    case days(Int)
    case indefinite
    case immediate

    public static let standard: RawAudioRetentionPolicy = .days(30)
}

public struct RawAudioRetentionDecision: Equatable, Sendable {
    public let eligible: Bool
    public let reason: String
}

public struct RawAudioRetentionEvaluator: Sendable {
    public init() {}
    public func decision(for endedAt: Date?, now: Date = Date(), policy: RawAudioRetentionPolicy) -> RawAudioRetentionDecision {
        guard let endedAt else { return RawAudioRetentionDecision(eligible: false, reason: "Session is active.") }
        switch policy {
        case .indefinite: return RawAudioRetentionDecision(eligible: false, reason: "Retention is indefinite.")
        case .immediate: return RawAudioRetentionDecision(eligible: true, reason: "Immediate deletion policy.")
        case let .days(days):
            let eligible = now.timeIntervalSince(endedAt) >= Double(days) * 86_400
            return RawAudioRetentionDecision(eligible: eligible, reason: eligible ? "Retention window elapsed." : "Retention window remains active.")
        }
    }
}

public struct SessionDeletionReport: Equatable, Sendable {
    public let deletedSession: Bool
    public let remainingPaths: [String]
    public let retryable: Bool
}

public protocol SessionArtifactRemoving: Sendable {
    func fileExists(atPath path: String) -> Bool
    func removeItem(at URL: URL) throws
}

public struct FileManagerArtifactRemover: SessionArtifactRemoving {
    public init() {}
    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    public func removeItem(at URL: URL) throws {
        try FileManager.default.removeItem(at: URL)
    }
}

@MainActor
public struct SessionDeletionCoordinator {
    private let database: LectureDatabase
    private let fileManager: any SessionArtifactRemoving
    private let sessionRoot: URL
    public init(
        database: LectureDatabase,
        sessionRoot: URL,
        fileManager: any SessionArtifactRemoving = FileManagerArtifactRemover()
    ) {
        self.database = database
        self.sessionRoot = sessionRoot
        self.fileManager = fileManager
    }
    public func delete(sessionID: SessionID) throws -> SessionDeletionReport {
        let directory = sessionRoot.appendingPathComponent(
            sessionID.rawValue.uuidString,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                return SessionDeletionReport(
                    deletedSession: false,
                    remainingPaths: [directory.path],
                    retryable: true
                )
            }
        }
        try database.execute(
            "DELETE FROM lecture_sessions WHERE id = ?",
            bindings: [.text(sessionID.rawValue.uuidString)]
        )
        return SessionDeletionReport(
            deletedSession: true,
            remainingPaths: [],
            retryable: false
        )
    }
}

public struct LectureSnapshot: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable { public let id: String; public let start: TimeInterval; public let end: TimeInterval; public let text: String; public let isGap: Bool }
    public struct Translation: Codable, Equatable, Sendable { public let sourceRevisionID: TranscriptRevisionID; public let languageCode: String; public let text: String }
    public let sessionID: SessionID
    public let title: String
    public let segments: [Segment]
    public let translations: [Translation]
    public let bookmarks: [LectureBookmark]
    public init(sessionID: SessionID, title: String, segments: [Segment], translations: [Translation], bookmarks: [LectureBookmark]) {
        self.sessionID = sessionID; self.title = title; self.segments = segments; self.translations = translations; self.bookmarks = bookmarks
    }
}

public struct LectureSnapshotExporter: Sendable {
    public init() {}
    public func json(_ snapshot: LectureSnapshot) throws -> Data { try JSONEncoder().encode(snapshot) }
    public func markdown(_ snapshot: LectureSnapshot) -> String {
        var result = "# \(snapshot.title)\n\n"
        for segment in snapshot.segments {
            let marker = segment.isGap ? "[Missing transcript]" : segment.text
            result += "- [\(timestamp(segment.start))–\(timestamp(segment.end))] \(marker)\n"
        }
        if !snapshot.translations.isEmpty {
            result += "\n## Simplified Chinese\n\n"
            snapshot.translations.forEach { result += "- \($0.text)\n" }
        }
        return result
    }
    @MainActor
    public func pdf(_ snapshot: LectureSnapshot) -> Data {
        let page = NSRect(x: 0, y: 0, width: 612, height: 792)
        let textView = NSTextView(frame: page.insetBy(dx: 36, dy: 36))
        textView.string = markdown(snapshot)
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return textView.dataWithPDF(inside: textView.bounds)
    }
    public func srt(_ snapshot: LectureSnapshot) -> String {
        let ordered = snapshot.segments.sorted {
            ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id)
        }
        return ordered.enumerated().map { index, segment in
            let nextStart = ordered.indices.contains(index + 1)
                ? ordered[index + 1].start
                : segment.end
            let end = max(segment.start, min(segment.end, nextStart))
            let text = segment.isGap ? "[Missing transcript]" : segment.text
            return "\(index + 1)\n\(srtTimestamp(segment.start)) --> \(srtTimestamp(end))\n\(text)\n"
        }.joined(separator: "\n")
    }
    private func timestamp(_ value: TimeInterval) -> String { String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60)) }
    private func srtTimestamp(_ value: TimeInterval) -> String { String(format: "%02d:%02d:%02d,%03d", Int(value) / 3600, Int(value) / 60 % 60, Int(value) % 60, Int(value * 1000) % 1000) }
}
