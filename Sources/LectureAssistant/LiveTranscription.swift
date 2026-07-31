import AVFoundation
import FluidAudio
import Foundation

public protocol StreamingSpeechRecognizing: Sendable {
    func consume(_ buffer: AVAudioPCMBuffer) async throws -> String
    func finalize() async throws -> String
    func reset() async
}

public actor NemotronStreamingSpeechRecognizer: StreamingSpeechRecognizing {
    private let manager: StreamingNemotronAsrManager

    public init(modelFolder: URL) async throws {
        let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
        try await manager.loadModels(from: modelFolder)
        self.manager = manager
    }

    public func consume(_ buffer: AVAudioPCMBuffer) async throws -> String {
        _ = try await manager.process(audioBuffer: buffer)
        return await manager.getPartialTranscript()
    }

    public func finalize() async throws -> String {
        let transcript = try await manager.finish()
        await manager.reset()
        return transcript
    }

    public func reset() async {
        await manager.reset()
    }
}

public struct LiveTranscriptSegment: Equatable, Sendable {
    public let id: String
    public let sessionID: SessionID
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let isFinal: Bool
    public let revisionID: TranscriptRevisionID?
    public let isGap: Bool

    public init(
        id: String,
        sessionID: SessionID,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        isFinal: Bool,
        isGap: Bool = false,
        revisionID: TranscriptRevisionID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
        self.isGap = isGap
        self.revisionID = revisionID
    }
}

public actor LiveTranscriptionPipeline {
    private let sessionID: SessionID
    private let recognizer: any StreamingSpeechRecognizing
    private let repository: SQLiteTranscriptRevisionRepository?
    private let speechActivationDecibels: Float
    private let relativeSilenceDropDecibels: Float
    private let finalSilenceSeconds: TimeInterval
    private var timelineSeconds: TimeInterval = 0
    private var utteranceStart: TimeInterval?
    private var silenceSeconds: TimeInterval = 0
    private var utterancePeakDecibels: Float?
    private var segmentIndex = 0
    private var lastPartial = ""
    private var lastCapturedAt: ContinuousClock.Instant?
    private var isSuspended = false
    private let latencyTracker: CaptionLatencyTracker
    private let latencyStream: BoundedAsyncStream<CaptionLatencyStatus>
    private let outputStream: BoundedAsyncStream<LiveTranscriptSegment>
    public nonisolated let segments: AsyncStream<LiveTranscriptSegment>
    public nonisolated let latencyStatuses: AsyncStream<CaptionLatencyStatus>

    public init(
        sessionID: SessionID,
        recognizer: any StreamingSpeechRecognizing,
        repository: SQLiteTranscriptRevisionRepository? = nil,
        speechActivationDecibels: Float = -38,
        relativeSilenceDropDecibels: Float = 18,
        finalSilenceSeconds: TimeInterval = 0.45,
        outputBufferLimit: Int = 32,
        latencyTracker: CaptionLatencyTracker = CaptionLatencyTracker()
    ) {
        self.sessionID = sessionID
        self.recognizer = recognizer
        self.repository = repository
        self.speechActivationDecibels = speechActivationDecibels
        self.relativeSilenceDropDecibels = relativeSilenceDropDecibels
        self.finalSilenceSeconds = finalSilenceSeconds
        self.latencyTracker = latencyTracker
        let outputStream = BoundedAsyncStream<LiveTranscriptSegment>(limit: outputBufferLimit)
        self.outputStream = outputStream
        segments = outputStream.stream
        let latencyStream = BoundedAsyncStream<CaptionLatencyStatus>(limit: outputBufferLimit)
        self.latencyStream = latencyStream
        latencyStatuses = latencyStream.stream
    }

    public func consume(_ frame: CapturedAudioFrame) async {
        guard !isSuspended else { return }
        let duration = frameDuration(frame.buffer)
        let frameStart = timelineSeconds
        timelineSeconds += duration
        lastCapturedAt = frame.capturedAt
        let containsSpeech: Bool
        if let utterancePeakDecibels {
            let adaptiveBoundary = max(
                speechActivationDecibels,
                utterancePeakDecibels - relativeSilenceDropDecibels
            )
            containsSpeech = frame.activity.decibels > adaptiveBoundary
            self.utterancePeakDecibels = max(utterancePeakDecibels, frame.activity.decibels)
        } else {
            containsSpeech = frame.activity.decibels > speechActivationDecibels
        }

        guard utteranceStart != nil || containsSpeech else { return }
        if utteranceStart == nil {
            utteranceStart = frameStart
            utterancePeakDecibels = frame.activity.decibels
            silenceSeconds = 0
        }
        silenceSeconds = containsSpeech ? 0 : silenceSeconds + duration

        do {
            let partial = normalized(try await recognizer.consume(frame.buffer))
            if !partial.isEmpty, partial != lastPartial {
                lastPartial = partial
                await emit(text: partial, final: false, completedAt: frame.capturedAt)
            }
            if silenceSeconds >= finalSilenceSeconds {
                await finalizeUtterance(completedAt: frame.capturedAt)
            }
        } catch {
            await emitGap(reason: error.localizedDescription, completedAt: frame.capturedAt)
        }
    }

    public func pause() async {
        isSuspended = true
        await finalizeUtterance(completedAt: lastCapturedAt ?? .now)
    }

    public func resume() {
        isSuspended = false
    }

    public func finish() async {
        await finalizeUtterance(completedAt: lastCapturedAt ?? .now)
        outputStream.finish()
        latencyStream.finish()
    }

    private func finalizeUtterance(completedAt: ContinuousClock.Instant) async {
        guard let start = utteranceStart else { return }
        do {
            let finalText = normalized(try await recognizer.finalize())
            if !finalText.isEmpty {
                let segmentID = "segment-\(segmentIndex)"
                let revision = try? await repository?.createRevision(
                    sessionID: sessionID,
                    segmentID: segmentID,
                    startsAt: start,
                    endsAt: timelineSeconds,
                    text: finalText,
                    status: .finalized
                )
                outputStream.yield(LiveTranscriptSegment(
                    id: segmentID,
                    sessionID: sessionID,
                    start: start,
                    end: timelineSeconds,
                    text: finalText,
                    isFinal: true,
                    revisionID: revision?.id
                ))
                await recordLatency(completedAt)
                segmentIndex += 1
            }
            resetUtterance()
        } catch {
            await emitGap(reason: error.localizedDescription, completedAt: completedAt)
        }
    }

    private func emit(
        text: String,
        final: Bool,
        completedAt: ContinuousClock.Instant
    ) async {
        guard let start = utteranceStart else { return }
        outputStream.yield(LiveTranscriptSegment(
            id: "segment-\(segmentIndex)",
            sessionID: sessionID,
            start: start,
            end: timelineSeconds,
            text: text,
            isFinal: final
        ))
        await recordLatency(completedAt)
    }

    private func emitGap(
        reason: String,
        completedAt: ContinuousClock.Instant
    ) async {
        guard let start = utteranceStart else { return }
        await recognizer.reset()
        let segmentID = "gap-\(segmentIndex)"
        outputStream.yield(LiveTranscriptSegment(
            id: segmentID,
            sessionID: sessionID,
            start: start,
            end: timelineSeconds,
            text: reason,
            isFinal: true,
            isGap: true
        ))
        _ = try? await repository?.createRevision(
            sessionID: sessionID,
            segmentID: segmentID,
            startsAt: start,
            endsAt: timelineSeconds,
            text: reason,
            status: .gap
        )
        await recordLatency(completedAt)
        segmentIndex += 1
        resetUtterance()
    }

    private func resetUtterance() {
        utteranceStart = nil
        silenceSeconds = 0
        utterancePeakDecibels = nil
        lastPartial = ""
    }

    private func recordLatency(_ completedAt: ContinuousClock.Instant) async {
        let latency = await latencyTracker.record(windowCompletedAt: completedAt)
        latencyStream.yield(latency)
    }

    private func frameDuration(_ buffer: AVAudioPCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
