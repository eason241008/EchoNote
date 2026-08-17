import AVFoundation
import Foundation
import NaturalLanguage
import WhisperKit

public struct SpeechRecognitionOutput: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public protocol LocalSpeechRecognizing: Sendable {
    func transcribe(samples: [Float], prompt: String?) async throws -> [SpeechRecognitionOutput]
}

public actor WhisperKitSpeechRecognizer: LocalSpeechRecognizing {
    private let whisperKit: WhisperKit

    public init(modelFolder: URL) async throws {
        whisperKit = try await WhisperKit(WhisperKitConfig(
            model: SpeechModelDescriptor.largeV3Compressed.id,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        ))
    }

    public func transcribe(samples: [Float], prompt: String?) async throws -> [SpeechRecognitionOutput] {
        // The compressed large-v3 model can return an empty transcript when the
        // legacy small.en prompt-token path is used. Keep the protocol stable,
        // but let this model decode without manually injected prompt tokens.
        _ = prompt
        let options = DecodingOptions(language: "en")
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).compactMap {
            let text = sanitizeTranscript($0.text)
            guard !text.isEmpty else { return nil }
            return SpeechRecognitionOutput(text: text, start: Double($0.start), end: Double($0.end))
        }
    }

    private func sanitizeTranscript(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]+\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    private struct RecognitionJob: Sendable {
        let samples: [Float]
        let final: Bool
        let windowStart: TimeInterval
        let segmentIndex: Int
        let windowCompletedAt: ContinuousClock.Instant
    }

    private let sessionID: SessionID
    private let recognizer: any LocalSpeechRecognizing
    private let repository: SQLiteTranscriptRevisionRepository?
    private let sampleRate = 16_000
    private let finalWindowSamples: Int
    private let partialWindowSamples: Int
    private var pendingSamples: [Float] = []
    private var consumedSamples = 0
    private var segmentIndex = 0
    private var nextPartialThreshold: Int
    private var finalJobs: [RecognitionJob] = []
    private var pendingPartialJob: RecognitionJob?
    private var recognitionTask: Task<Void, Never>?
    private var isFinishing = false
    private var prompt: String?
    private var lastCapturedAt: ContinuousClock.Instant?
    private let latencyTracker: CaptionLatencyTracker
    private let latencyStream: BoundedAsyncStream<CaptionLatencyStatus>
    private let outputStream: BoundedAsyncStream<LiveTranscriptSegment>
    public nonisolated let segments: AsyncStream<LiveTranscriptSegment>
    public nonisolated let latencyStatuses: AsyncStream<CaptionLatencyStatus>

    public init(
        sessionID: SessionID,
        recognizer: any LocalSpeechRecognizing,
        repository: SQLiteTranscriptRevisionRepository? = nil,
        finalWindowSeconds: Double = 30,
        partialWindowSeconds: Double = 5,
        outputBufferLimit: Int = 32,
        latencyTracker: CaptionLatencyTracker = CaptionLatencyTracker()
    ) {
        self.sessionID = sessionID
        self.recognizer = recognizer
        self.repository = repository
        self.latencyTracker = latencyTracker
        let finalSamples = max(1, Int(finalWindowSeconds * Double(sampleRate)))
        let partialSamples = max(1, Int(partialWindowSeconds * Double(sampleRate)))
        finalWindowSamples = finalSamples
        partialWindowSamples = partialSamples
        nextPartialThreshold = partialSamples
        let outputStream = BoundedAsyncStream<LiveTranscriptSegment>(limit: outputBufferLimit)
        self.outputStream = outputStream
        segments = outputStream.stream
        let latencyStream = BoundedAsyncStream<CaptionLatencyStatus>(limit: outputBufferLimit)
        self.latencyStream = latencyStream
        latencyStatuses = latencyStream.stream
    }

    public func updatePrompt(_ prompt: String?) {
        self.prompt = Self.englishPrompt(from: prompt)
    }

    static func englishPrompt(from prompt: String?) -> String? {
        guard let prompt else { return nil }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let letters = normalized.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty,
              letters.allSatisfy({ $0.isASCII }) else { return nil }
        return normalized
    }

    public func consume(_ frame: CapturedAudioFrame) async {
        guard !isFinishing else { return }
        lastCapturedAt = frame.capturedAt
        do {
            pendingSamples.append(contentsOf: try frame.buffer.samples16kMono())
        } catch {
            await emitGap(sampleCount: Int(frame.buffer.frameLength), reason: "Audio conversion failed")
            return
        }

        while pendingSamples.count >= finalWindowSamples {
            let window = Array(pendingSamples.prefix(finalWindowSamples))
            pendingSamples.removeFirst(finalWindowSamples)
            finalJobs.append(RecognitionJob(
                samples: window,
                final: true,
                windowStart: Double(consumedSamples) / Double(sampleRate),
                segmentIndex: segmentIndex,
                windowCompletedAt: frame.capturedAt
            ))
            consumedSamples += window.count
            segmentIndex += 1
            nextPartialThreshold = partialWindowSamples
        }

        if pendingSamples.count >= nextPartialThreshold {
            while nextPartialThreshold <= pendingSamples.count {
                nextPartialThreshold += partialWindowSamples
            }
            pendingPartialJob = RecognitionJob(
                samples: pendingSamples,
                final: false,
                windowStart: Double(consumedSamples) / Double(sampleRate),
                segmentIndex: segmentIndex,
                windowCompletedAt: frame.capturedAt
            )
        }
        startRecognitionWorkerIfNeeded()
    }

    public func finish() async {
        guard !isFinishing else {
            await recognitionTask?.value
            return
        }
        isFinishing = true
        if !pendingSamples.isEmpty {
            let samples = pendingSamples
            pendingSamples.removeAll(keepingCapacity: false)
            finalJobs.append(RecognitionJob(
                samples: samples,
                final: true,
                windowStart: Double(consumedSamples) / Double(sampleRate),
                segmentIndex: segmentIndex,
                windowCompletedAt: lastCapturedAt ?? .now
            ))
            consumedSamples += samples.count
            segmentIndex += 1
        }
        startRecognitionWorkerIfNeeded()
        await recognitionTask?.value
        outputStream.finish()
        latencyStream.finish()
    }

    private func startRecognitionWorkerIfNeeded() {
        guard recognitionTask == nil,
              !finalJobs.isEmpty || pendingPartialJob != nil else { return }
        recognitionTask = Task { [weak self] in
            await self?.drainRecognitionJobs()
        }
    }

    private func drainRecognitionJobs() async {
        while let job = dequeueRecognitionJob() {
            await recognize(job)
        }
        recognitionTask = nil
    }

    private func dequeueRecognitionJob() -> RecognitionJob? {
        if let partial = pendingPartialJob,
           finalJobs.first.map({ partial.segmentIndex <= $0.segmentIndex }) ?? true {
            pendingPartialJob = nil
            return partial
        }
        if !finalJobs.isEmpty {
            return finalJobs.removeFirst()
        }
        return nil
    }

    private func recognize(_ job: RecognitionJob) async {
        do {
            let outputs = try await recognizer.transcribe(samples: job.samples, prompt: prompt)
            let paragraphs = Self.paragraphOutputs(outputs, maximumSentenceCount: 2)
            guard !paragraphs.isEmpty else {
                return
            }
            for (paragraphIndex, output) in paragraphs.enumerated() {
                let segmentID = "segment-\(job.segmentIndex)-\(paragraphIndex)"
                let revision: TranscriptRevision?
                if job.final, let repository {
                    revision = try? await repository.createRevision(
                        sessionID: sessionID,
                        segmentID: segmentID,
                        startsAt: job.windowStart + output.start,
                        endsAt: job.windowStart + output.end,
                        text: output.text,
                        status: .finalized
                    )
                } else {
                    revision = nil
                }
                let segment = LiveTranscriptSegment(
                    id: segmentID,
                    sessionID: sessionID,
                    start: job.windowStart + output.start,
                    end: job.windowStart + output.end,
                    text: output.text,
                    isFinal: job.final,
                    revisionID: revision?.id
                )
                outputStream.yield(segment)
            }
            let latency = await latencyTracker.record(windowCompletedAt: job.windowCompletedAt)
            latencyStream.yield(latency)
        } catch {
            if job.final {
                await emitGap(
                    start: job.windowStart,
                    sampleCount: job.samples.count,
                    segmentIndex: job.segmentIndex,
                    reason: error.localizedDescription
                )
            }
        }
    }

    static func mergedOutput(_ outputs: [SpeechRecognitionOutput]) -> SpeechRecognitionOutput? {
        let usable = outputs.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let first = usable.first, let last = usable.last else { return nil }
        let text = usable.map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechRecognitionOutput(text: text, start: first.start, end: last.end)
    }

    static func paragraphOutputs(
        _ outputs: [SpeechRecognitionOutput],
        maximumSentenceCount: Int = 2
    ) -> [SpeechRecognitionOutput] {
        guard maximumSentenceCount > 0, let merged = mergedOutput(outputs) else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = merged.text
        var sentenceRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: merged.text.startIndex..<merged.text.endIndex) { range, _ in
            sentenceRanges.append(range)
            return true
        }
        guard !sentenceRanges.isEmpty else { return [merged] }

        let characterCount = max(1, merged.text.count)
        let duration = max(0, merged.end - merged.start)
        return stride(from: 0, to: sentenceRanges.count, by: maximumSentenceCount).map { index in
            let group = sentenceRanges[index..<min(sentenceRanges.count, index + maximumSentenceCount)]
            let lowerBound = group.first!.lowerBound
            let upperBound = group.last!.upperBound
            let startOffset = merged.text.distance(from: merged.text.startIndex, to: lowerBound)
            let endOffset = merged.text.distance(from: merged.text.startIndex, to: upperBound)
            let text = String(merged.text[lowerBound..<upperBound])
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechRecognitionOutput(
                text: text,
                start: merged.start + duration * Double(startOffset) / Double(characterCount),
                end: merged.start + duration * Double(endOffset) / Double(characterCount)
            )
        }
        .filter { !$0.text.isEmpty }
    }

    private func emitGap(sampleCount: Int, reason: String) async {
        let start = Double(consumedSamples) / Double(sampleRate)
        let gapSegmentIndex = segmentIndex
        consumedSamples += sampleCount
        segmentIndex += 1
        await emitGap(
            start: start,
            sampleCount: sampleCount,
            segmentIndex: gapSegmentIndex,
            reason: reason
        )
    }

    private func emitGap(
        start: TimeInterval,
        sampleCount: Int,
        segmentIndex: Int,
        reason: String
    ) async {
        let end = start + Double(sampleCount) / Double(sampleRate)
        let segmentID = "gap-\(segmentIndex)"
        let gap = LiveTranscriptSegment(
            id: segmentID,
            sessionID: sessionID,
            start: start,
            end: end,
            text: reason,
            isFinal: true,
            isGap: true
        )
        outputStream.yield(gap)
        if let repository {
            _ = try? await repository.createRevision(
                sessionID: sessionID,
                segmentID: segmentID,
                startsAt: start,
                endsAt: end,
                text: reason,
                status: .gap
            )
        }
    }
}

public enum AudioConversionError: Error {
    case unsupportedFormat
    case conversionFailed
}

extension AVAudioPCMBuffer {
    func samples16kMono() throws -> [Float] {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        if format.sampleRate == 16_000, format.channelCount == 1,
           let channel = floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(frameLength)))
        }
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw AudioConversionError.unsupportedFormat
        }
        let ratio = targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AudioConversionError.unsupportedFormat
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return self
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData?[0] else {
            throw AudioConversionError.conversionFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
