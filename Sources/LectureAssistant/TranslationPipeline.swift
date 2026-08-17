import Foundation

public struct TranslationSourceSegment: Codable, Equatable, Sendable {
    public let revisionID: TranscriptRevisionID
    public let text: String

    public init(revisionID: TranscriptRevisionID, text: String) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TranslationContractError.emptySourceText }
        self.revisionID = revisionID
        self.text = normalized
    }
}

public struct SimplifiedChineseTranslationRequest: Codable, Equatable, Sendable {
    public let segments: [TranslationSourceSegment]
    public let terminology: [String]

    public init(segments: [TranslationSourceSegment], terminology: [String] = []) throws {
        guard !segments.isEmpty else { throw TranslationContractError.emptyBatch }
        self.segments = segments
        self.terminology = terminology
    }
}

public struct SimplifiedChineseTranslation: Codable, Equatable, Sendable {
    public let revisionID: TranscriptRevisionID
    public let text: String

    public init(revisionID: TranscriptRevisionID, text: String) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TranslationContractError.emptyTranslation }
        self.revisionID = revisionID
        self.text = normalized
    }
}

public struct SimplifiedChineseTranslationResponse: Codable, Equatable, Sendable {
    public let translations: [SimplifiedChineseTranslation]

    public init(
        translations: [SimplifiedChineseTranslation],
        matching request: SimplifiedChineseTranslationRequest
    ) throws {
        let expected = request.segments.map(\.revisionID)
        let received = translations.map(\.revisionID)
        guard received == expected else { throw TranslationContractError.revisionMismatch }
        self.translations = translations
    }
}

public enum TranslationContractError: LocalizedError, Equatable {
    case emptyBatch
    case emptySourceText
    case emptyTranslation
    case revisionMismatch
    case malformedProviderOutput

    public var errorDescription: String? {
        switch self {
        case .emptyBatch: return "A translation batch must contain text."
        case .emptySourceText: return "Translation source text is empty."
        case .emptyTranslation: return "The provider returned an empty translation."
        case .revisionMismatch: return "The provider response does not match the source revisions."
        case .malformedProviderOutput: return "The provider returned malformed translation output."
        }
    }
}

public enum TranslationProviderError: LocalizedError, Equatable {
    case unauthorized
    case quotaLimited
    case timedOut
    case offline
    case rejected(Int)

    public var isRetryable: Bool {
        switch self {
        case .quotaLimited, .timedOut, .offline: return true
        case .unauthorized, .rejected: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Translation credentials were rejected."
        case .quotaLimited: return "The translation provider quota is temporarily unavailable."
        case .timedOut: return "The translation request timed out."
        case .offline: return "Translation is unavailable while offline."
        case let .rejected(status): return "The translation provider rejected the request (HTTP \(status))."
        }
    }
}

public protocol SimplifiedChineseTranslationProviding: Sendable {
    var providerID: String { get }
    var model: String { get }
    func translate(_ request: SimplifiedChineseTranslationRequest) async throws
        -> SimplifiedChineseTranslationResponse
}


public struct PendingTranslationRevision: Equatable, Sendable {
    public let sessionID: SessionID
    public let revisionID: TranscriptRevisionID
    public let text: String

    public init(sessionID: SessionID, revisionID: TranscriptRevisionID, text: String) {
        self.sessionID = sessionID
        self.revisionID = revisionID
        self.text = text
    }
}

public enum TranslationPipelineState: Equatable, Sendable {
    case englishOnly
    case queued(Int)
    case translating(Int)
    case translated([TranscriptRevisionID])
    case failed(retryable: Bool, message: String)
}

public actor TranslationPipeline {
    private let provider: (any SimplifiedChineseTranslationProviding)?
    private let repository: SQLiteTranslationRepository?
    private let batchingDelay: Duration
    private let capacity: Int
    private let maximumBatchSize: Int
    private var pending: [PendingTranslationRevision] = []
    private var flushTask: Task<Void, Never>?
    private var terminology: [String] = []
    private let stateStream: BoundedAsyncStream<TranslationPipelineState>
    public nonisolated let states: AsyncStream<TranslationPipelineState>
    private let resultStream: BoundedAsyncStream<SimplifiedChineseTranslation>
    public nonisolated let results: AsyncStream<SimplifiedChineseTranslation>

    public init(
        provider: (any SimplifiedChineseTranslationProviding)?,
        repository: SQLiteTranslationRepository? = nil,
        batchingDelay: Duration = .milliseconds(500),
        capacity: Int = 64,
        maximumBatchSize: Int = 8
    ) {
        self.provider = provider
        self.repository = repository
        self.batchingDelay = batchingDelay
        self.capacity = max(1, capacity)
        self.maximumBatchSize = max(1, maximumBatchSize)
        let stateStream = BoundedAsyncStream<TranslationPipelineState>(limit: 32)
        self.stateStream = stateStream
        states = stateStream.stream
        let resultStream = BoundedAsyncStream<SimplifiedChineseTranslation>(limit: 64)
        self.resultStream = resultStream
        results = resultStream.stream
        if provider == nil { stateStream.yield(.englishOnly) }
    }

    public func updateTerminology(_ terminology: [String]) {
        self.terminology = terminology
    }

    public func enqueue(_ revision: PendingTranslationRevision) {
        guard provider != nil else {
            stateStream.yield(.englishOnly)
            return
        }
        if pending.count == capacity { pending.removeFirst() }
        pending.append(revision)
        stateStream.yield(.queued(pending.count))
        scheduleFlushIfNeeded()
    }

    public func retry() async {
        await flushNow()
    }

    public func finish() async {
        if let flushTask {
            await flushTask.value
        }
        while !pending.isEmpty {
            guard await flushNow() else { break }
        }
        resultStream.finish()
        stateStream.finish()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil, !pending.isEmpty else { return }
        flushTask = Task { [batchingDelay] in
            try? await Task.sleep(for: batchingDelay)
            await self.flushScheduledBatch()
        }
    }

    private func flushScheduledBatch() async {
        let succeeded = await flushNow()
        flushTask = nil
        if succeeded {
            scheduleFlushIfNeeded()
        }
    }

    @discardableResult
    private func flushNow() async -> Bool {
        guard let provider, !pending.isEmpty else { return true }
        let batchSize = min(maximumBatchSize, pending.count)
        let batch = Array(pending.prefix(batchSize))
        pending.removeFirst(batchSize)
        stateStream.yield(.translating(batch.count))
        do {
            let segments = try batch.map {
                try TranslationSourceSegment(revisionID: $0.revisionID, text: $0.text)
            }
            let request = try SimplifiedChineseTranslationRequest(
                segments: segments,
                terminology: terminology
            )
            let response = try await provider.translate(request)
            for (source, translation) in zip(batch, response.translations) {
                if let repository {
                    _ = try await repository.save(
                        sessionID: source.sessionID,
                        sourceRevisionID: source.revisionID,
                        languageCode: "zh-Hans",
                        text: translation.text,
                        providerID: provider.providerID,
                        model: provider.model
                    )
                }
                resultStream.yield(translation)
            }
            stateStream.yield(.translated(response.translations.map(\.revisionID)))
            return true
        } catch {
            pending.insert(contentsOf: batch, at: 0)
            let retryable = (error as? TranslationProviderError)?.isRetryable ?? false
            stateStream.yield(.failed(retryable: retryable, message: error.localizedDescription))
            return false
        }
    }
}
