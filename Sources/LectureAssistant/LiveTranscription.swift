import AVFoundation
import Foundation
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
            model: SpeechModelDescriptor.smallEnglish.id,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        ))
    }

    public func transcribe(samples: [Float], prompt: String?) async throws -> [SpeechRecognitionOutput] {
        var options = DecodingOptions(language: "en", wordTimestamps: true)
        if let prompt, !prompt.isEmpty, let tokenizer = whisperKit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " \(prompt)")
        }
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
    private let sessionID: SessionID
    private let recognizer: any LocalSpeechRecognizing
    private let repository: SQLiteTranscriptRevisionRepository?
    private let sampleRate = 16_000
    private let finalWindowSamples: Int
    private let partialWindowSamples: Int
    private var pendingSamples: [Float] = []
    private var consumedSamples = 0
    private var segmentIndex = 0
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
        finalWindowSeconds: Double = 5,
        partialWindowSeconds: Double = 1,
        outputBufferLimit: Int = 32,
        latencyTracker: CaptionLatencyTracker = CaptionLatencyTracker()
    ) {
        self.sessionID = sessionID
        self.recognizer = recognizer
        self.repository = repository
        self.latencyTracker = latencyTracker
        finalWindowSamples = max(1, Int(finalWindowSeconds * Double(sampleRate)))
        partialWindowSamples = max(1, Int(partialWindowSeconds * Double(sampleRate)))
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
        lastCapturedAt = frame.capturedAt
        do {
            pendingSamples.append(contentsOf: try frame.buffer.samples16kMono())
        } catch {
            await emitGap(sampleCount: Int(frame.buffer.frameLength), reason: "Audio conversion failed")
            return
        }
        if pendingSamples.count >= finalWindowSamples {
            let window = Array(pendingSamples.prefix(finalWindowSamples))
            pendingSamples.removeFirst(finalWindowSamples)
            await recognize(window, final: true, windowCompletedAt: frame.capturedAt)
        } else if pendingSamples.count >= partialWindowSamples,
                  pendingSamples.count % partialWindowSamples < Int(frame.buffer.frameLength) {
            await recognize(pendingSamples, final: false, windowCompletedAt: frame.capturedAt)
        }
    }

    public func finish() async {
        if !pendingSamples.isEmpty {
            let samples = pendingSamples
            pendingSamples.removeAll(keepingCapacity: false)
            await recognize(
                samples,
                final: true,
                windowCompletedAt: lastCapturedAt ?? .now
            )
        }
        outputStream.finish()
        latencyStream.finish()
    }

    private func recognize(
        _ samples: [Float],
        final: Bool,
        windowCompletedAt: ContinuousClock.Instant
    ) async {
        let windowStart = Double(consumedSamples) / Double(sampleRate)
        do {
            let outputs = try await recognizer.transcribe(samples: samples, prompt: prompt)
            if outputs.isEmpty && final {
                await emitGap(sampleCount: samples.count, reason: "No trustworthy transcription")
                return
            }
            for output in outputs {
                let segmentID = "segment-\(segmentIndex)"
                let revision: TranscriptRevision?
                if final, let repository {
                    revision = try? await repository.createRevision(
                        sessionID: sessionID,
                        segmentID: segmentID,
                        startsAt: windowStart + output.start,
                        endsAt: windowStart + output.end,
                        text: output.text,
                        status: .finalized
                    )
                } else {
                    revision = nil
                }
                let segment = LiveTranscriptSegment(
                    id: segmentID,
                    sessionID: sessionID,
                    start: windowStart + output.start,
                    end: windowStart + output.end,
                    text: output.text,
                    isFinal: final,
                    revisionID: revision?.id
                )
                outputStream.yield(segment)
                if final { segmentIndex += 1 }
            }
            if !outputs.isEmpty {
                let latency = await latencyTracker.record(windowCompletedAt: windowCompletedAt)
                latencyStream.yield(latency)
            }
            if final { consumedSamples += samples.count }
        } catch {
            if final {
                await emitGap(sampleCount: samples.count, reason: error.localizedDescription)
            }
        }
    }

    private func emitGap(sampleCount: Int, reason: String) async {
        let start = Double(consumedSamples) / Double(sampleRate)
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
        consumedSamples += sampleCount
        segmentIndex += 1
    }
}

public enum AudioConversionError: Error {
    case unsupportedFormat
    case conversionFailed
}

private extension AVAudioPCMBuffer {
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
