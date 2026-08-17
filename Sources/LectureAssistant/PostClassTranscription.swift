import AVFoundation
import Foundation

public struct PostClassTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(id: String, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct PostClassTranscriptDocument: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1

    public let version: Int
    public let id: UUID
    public let sessionID: SessionID
    public let title: String
    public let generatedAt: Date
    public let model: String
    public let segments: [PostClassTranscriptSegment]

    public init(
        version: Int = currentVersion,
        id: UUID = UUID(),
        sessionID: SessionID,
        title: String,
        generatedAt: Date = Date(),
        model: String = SpeechModelDescriptor.largeV3Compressed.id,
        segments: [PostClassTranscriptSegment]
    ) {
        self.version = version
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.generatedAt = generatedAt
        self.model = model
        self.segments = segments
    }
}

public enum PostClassTranscriptionError: LocalizedError, Equatable {
    case noFinalizedAudio
    case unsupportedAudio

    public var errorDescription: String? {
        switch self {
        case .noFinalizedAudio:
            return "没有可用于课后校对的完整课堂音频。"
        case .unsupportedAudio:
            return "课堂音频无法转换为课后转写所需的格式。"
        }
    }
}

public actor PostClassTranscriptionService {
    private let storage: SessionStorage
    private let recognizer: any LocalSpeechRecognizing
    private let analysisWindowSamples: Int

    public init(
        storage: SessionStorage,
        recognizer: any LocalSpeechRecognizing,
        analysisWindowSeconds: Double = 5 * 60
    ) {
        self.storage = storage
        self.recognizer = recognizer
        analysisWindowSamples = max(16_000, Int(analysisWindowSeconds * 16_000))
    }

    @discardableResult
    public func generate(
        sessionID: SessionID,
        title: String
    ) async throws -> PostClassTranscriptDocument {
        let manifest = try await storage.loadManifest(sessionID: sessionID)
        guard !manifest.chunks.isEmpty else {
            throw PostClassTranscriptionError.noFinalizedAudio
        }

        var resultSegments: [PostClassTranscriptSegment] = []
        var outputIndex = 0
        for chunk in manifest.chunks.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            try Task.checkCancellation()
            let audioURL = try await storage.finalizedChunkURL(sessionID: sessionID, chunk: chunk)
            let reader = try AudioWindowReader(
                url: audioURL,
                maximumSampleCount: analysisWindowSamples
            )
            var windowStart = chunk.startsAt
            while let samples = try reader.nextWindow() {
                try Task.checkCancellation()
                let outputs = try await recognizer.transcribe(samples: samples, prompt: title)
                let paragraphs = LiveTranscriptionPipeline.paragraphOutputs(
                    outputs,
                    maximumSentenceCount: 2
                )
                for paragraph in paragraphs {
                    resultSegments.append(PostClassTranscriptSegment(
                        id: "post-class-\(outputIndex)",
                        start: windowStart + paragraph.start,
                        end: windowStart + paragraph.end,
                        text: paragraph.text
                    ))
                    outputIndex += 1
                }
                windowStart += Double(samples.count) / 16_000
            }
        }

        let document = PostClassTranscriptDocument(
            sessionID: sessionID,
            title: title,
            segments: resultSegments
        )
        _ = try await storage.savePostClassTranscript(document)
        return document
    }
}

private final class AudioWindowReader {
    private let file: AVAudioFile
    private let maximumSampleCount: Int
    private var pendingSamples: [Float] = []

    init(url: URL, maximumSampleCount: Int) throws {
        file = try AVAudioFile(forReading: url)
        self.maximumSampleCount = maximumSampleCount
    }

    func nextWindow() throws -> [Float]? {
        var samples: [Float] = []
        samples.reserveCapacity(maximumSampleCount)
        while samples.count < maximumSampleCount {
            if !pendingSamples.isEmpty {
                let count = min(maximumSampleCount - samples.count, pendingSamples.count)
                samples.append(contentsOf: pendingSamples.prefix(count))
                pendingSamples.removeFirst(count)
                continue
            }
            guard file.framePosition < file.length else { break }
            let remainingSourceFrames = file.length - file.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(32_768), remainingSourceFrames))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            ) else {
                throw PostClassTranscriptionError.unsupportedAudio
            }
            try file.read(into: buffer, frameCount: frameCount)
            let converted = try buffer.samples16kMono()
            let remaining = maximumSampleCount - samples.count
            samples.append(contentsOf: converted.prefix(remaining))
            if converted.count > remaining {
                pendingSamples.append(contentsOf: converted.dropFirst(remaining))
            }
        }
        return samples.isEmpty ? nil : samples
    }
}
