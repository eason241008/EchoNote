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

    private let jobWakeStream: AsyncStream<Void>
    private let jobWakeContinuation: AsyncStream<Void>.Continuation
    private let stateStream: BoundedAsyncStream<AppleTranslationServiceState>
    public nonisolated let states: AsyncStream<AppleTranslationServiceState>
    private var jobs: [Job] = []
    private var activeRunnerID: UUID?
    private var failure: Error?

    public init() {
        let stream = AsyncStream.makeStream(of: Void.self)
        jobWakeStream = stream.stream
        jobWakeContinuation = stream.continuation
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
            jobs.append(Job(request: request, continuation: continuation))
            jobWakeContinuation.yield(())
        }
    }

    public func needsRunnerRestart() -> Bool {
        !jobs.isEmpty && activeRunnerID == nil
    }

    public func run(session: any AppleTranslationSessionServing) async {
        let runnerID = UUID()
        activeRunnerID = runnerID
        failure = nil
        stateStream.yield(.preparing)
        do {
            try await session.prepareTranslation()
            guard activeRunnerID == runnerID, !Task.isCancelled else {
                deactivateRunner(runnerID)
                return
            }
            stateStream.yield(.ready)
            var wakeIterator = jobWakeStream.makeAsyncIterator()
            while activeRunnerID == runnerID, !Task.isCancelled {
                guard !jobs.isEmpty else {
                    guard await wakeIterator.next() != nil else { break }
                    continue
                }
                let job = jobs.removeFirst()
                do {
                    let response = try await translate(job.request, using: session)
                    job.continuation.resume(returning: response)
                } catch is CancellationError {
                    jobs.insert(job, at: 0)
                    break
                } catch {
                    job.continuation.resume(throwing: error)
                }
            }
            deactivateRunner(runnerID)
        } catch is CancellationError {
            deactivateRunner(runnerID)
            return
        } catch {
            guard activeRunnerID == runnerID else { return }
            failure = error
            stateStream.yield(.unavailable(error.localizedDescription))
            activeRunnerID = nil
            let queuedJobs = jobs
            jobs.removeAll(keepingCapacity: true)
            for job in queuedJobs {
                job.continuation.resume(throwing: error)
            }
        }
    }

    private func deactivateRunner(_ runnerID: UUID) {
        guard activeRunnerID == runnerID else { return }
        activeRunnerID = nil
        if !jobs.isEmpty {
            stateStream.yield(.preparing)
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
