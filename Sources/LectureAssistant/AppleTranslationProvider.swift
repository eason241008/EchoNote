import Foundation
import Translation

public enum AppleTranslationServiceState: Equatable, Sendable {
    case preparing
    case ready
    case unavailable(String)

    public var displayText: String {
        switch self {
        case .preparing:
            return "正在准备 Apple 本地翻译"
        case .ready:
            return "Apple 本地翻译已就绪"
        case let .unavailable(message):
            return message
        }
    }
}
public struct AppleTranslationRequest: Equatable, Sendable {
    public let sourceText: String
    public let clientIdentifier: String
}

public struct AppleTranslationResult: Equatable, Sendable {
    public let targetText: String
    public let clientIdentifier: String?
}

public protocol AppleTranslationSessionServing {
    func prepareTranslation() async throws
    func translations(from requests: [AppleTranslationRequest]) async throws
        -> [AppleTranslationResult]
}

public struct AppleTranslationSessionAdapter: AppleTranslationSessionServing {
    private let session: TranslationSession

    public init(session: TranslationSession) {
        self.session = session
    }

    public func prepareTranslation() async throws {
        try await session.prepareTranslation()
    }

    public func translations(
        from requests: [AppleTranslationRequest]
    ) async throws -> [AppleTranslationResult] {
        try await session.translations(from: requests.map {
            TranslationSession.Request(
                sourceText: $0.sourceText,
                clientIdentifier: $0.clientIdentifier
            )
        }).map {
            AppleTranslationResult(
                targetText: $0.targetText,
                clientIdentifier: $0.clientIdentifier
            )
        }
    }
}


public actor AppleTranslationProvider: SimplifiedChineseTranslationProviding {
    public nonisolated let providerID = "apple-translation"
    public nonisolated let model = "system-on-device"

    private struct Job: Sendable {
        let request: SimplifiedChineseTranslationRequest
        let continuation: CheckedContinuation<SimplifiedChineseTranslationResponse, Error>
    }

    private let jobStream: AsyncStream<Job>
    private let jobContinuation: AsyncStream<Job>.Continuation
    private let stateStream: BoundedAsyncStream<AppleTranslationServiceState>
    public nonisolated let states: AsyncStream<AppleTranslationServiceState>
    private var failure: Error?

    public init() {
        let stream = AsyncStream.makeStream(of: Job.self)
        jobStream = stream.stream
        jobContinuation = stream.continuation
        let stateStream = BoundedAsyncStream<AppleTranslationServiceState>(limit: 8)
        self.stateStream = stateStream
        states = stateStream.stream
        stateStream.yield(.preparing)
    }

    public func translate(
        _ request: SimplifiedChineseTranslationRequest
    ) async throws -> SimplifiedChineseTranslationResponse {
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            jobContinuation.yield(Job(request: request, continuation: continuation))
        }
    }

    public func run(session: any AppleTranslationSessionServing) async {
        failure = nil
        stateStream.yield(.preparing)
        do {
            try await session.prepareTranslation()
            stateStream.yield(.ready)
            for await job in jobStream {
                guard !Task.isCancelled else {
                    job.continuation.resume(throwing: CancellationError())
                    break
                }
                do {
                    job.continuation.resume(returning: try await translate(job.request, using: session))
                } catch {
                    job.continuation.resume(throwing: error)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            failure = error
            stateStream.yield(.unavailable(error.localizedDescription))
            for await job in jobStream {
                job.continuation.resume(throwing: error)
            }
        }
    }

    private func translate(
        _ request: SimplifiedChineseTranslationRequest,
        using session: any AppleTranslationSessionServing
    ) async throws -> SimplifiedChineseTranslationResponse {
        let batch = request.segments.map {
            AppleTranslationRequest(
                sourceText: $0.text,
                clientIdentifier: $0.revisionID.rawValue.uuidString
            )
        }
        let responses = try await session.translations(from: batch)
        let translations = try responses.map { response in
            guard let identifier = response.clientIdentifier,
                  let revisionID = UUID(uuidString: identifier)
            else { throw TranslationContractError.revisionMismatch }
            return try SimplifiedChineseTranslation(
                revisionID: TranscriptRevisionID(rawValue: revisionID),
                text: response.targetText
            )
        }
        return try SimplifiedChineseTranslationResponse(
            translations: translations,
            matching: request
        )
    }
}
