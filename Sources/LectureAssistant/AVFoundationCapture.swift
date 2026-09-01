import AVFoundation
import CoreAudio
import Foundation

public struct CapturedAudioFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let capturedAt: ContinuousClock.Instant
    public let activity: AudioActivityLevel
    public let sessionID: SessionID?

    public init(
        buffer: AVAudioPCMBuffer,
        capturedAt: ContinuousClock.Instant,
        activity: AudioActivityLevel,
        sessionID: SessionID? = nil
    ) {
        self.buffer = buffer
        self.capturedAt = capturedAt
        self.activity = activity
        self.sessionID = sessionID
    }
}

public enum AVFoundationCaptureError: LocalizedError, Equatable {
    case notPrepared
    case alreadyRunning
    case deviceSelectionFailed(OSStatus)
    case invalidInputFormat
    case audioEngineFailed
    case chunkWriteFailed

    public var errorDescription: String? {
        switch self {
        case .notPrepared: return "Prepare a lecture session before starting capture."
        case .alreadyRunning: return "Microphone capture is already running."
        case .deviceSelectionFailed: return "The selected microphone could not be activated."
        case .invalidInputFormat: return "The selected microphone has an unsupported input format."
        case .audioEngineFailed: return "The microphone audio engine could not start."
        case .chunkWriteFailed: return "Captured audio could not be written safely."
        }
    }
}

private final class CaptureWriterState: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.lectureassistant.capture-writer", qos: .userInitiated)
    var activeSink: CaptureWriterSink?
    var frameStream: BoundedAsyncStream<CapturedAudioFrame>?
}

private final class CaptureWriterSink: @unchecked Sendable {
    let sessionID: SessionID
    let chunkID: UUID
    let stagingURL: URL
    var audioFile: AVAudioFile?
    var failure: Error?

    init(sessionID: SessionID, chunkID: UUID, stagingURL: URL) {
        self.sessionID = sessionID
        self.chunkID = chunkID
        self.stagingURL = stagingURL
    }
}

public actor AVFoundationLectureCaptureService {
    // Passing a non-nil format makes AVFAudio call SetOutputFormat on the
    // microphone node. That can raise an Objective-C exception while macOS is
    // still settling a newly selected route. A nil tap format keeps the
    // device-negotiated format and avoids the uncatchable SIGABRT.
    static var inputTapFormat: AVAudioFormat? { nil }

    static func fallbackDeviceIDs(
        requestedDeviceID: AudioDeviceID,
        devices: [AudioInputDevice]
    ) -> [AudioDeviceID] {
        devices
            .filter { $0.id != requestedDeviceID }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map(\.id)
    }

    static func startAttemptDeviceIDs(
        requestedDeviceID: AudioDeviceID,
        devices: [AudioInputDevice],
        attemptsPerDevice: Int = 2
    ) -> [AudioDeviceID] {
        let orderedDevices = [requestedDeviceID] + fallbackDeviceIDs(
            requestedDeviceID: requestedDeviceID,
            devices: devices
        )
        return orderedDevices.flatMap {
            Array(repeating: $0, count: max(1, attemptsPerDevice))
        }
    }

    private let storage: SessionStorage
    private var engine: AVAudioEngine
    private let writer = CaptureWriterState()
    private let timeline: CaptureTimelineRecorder?
    private var preparation: LectureCapturePreparation?
    private var recordingStartedAt: ContinuousClock.Instant?
    private var isRunning = false
    private var isPaused = false
    private var retiredWriterTasks: [Task<Void, Never>] = []
    private let frameStream: BoundedAsyncStream<CapturedAudioFrame>
    public nonisolated let frames: AsyncStream<CapturedAudioFrame>
    public nonisolated var droppedFrameCount: Int { frameStream.droppedCount }

    public init(
        storage: SessionStorage,
        frameBufferLimit: Int = 512,
        timeline: CaptureTimelineRecorder? = nil
    ) {
        self.storage = storage
        self.timeline = timeline
        engine = AVAudioEngine()
        let frameStream = BoundedAsyncStream<CapturedAudioFrame>(limit: frameBufferLimit)
        self.frameStream = frameStream
        frames = frameStream.stream
        writer.frameStream = frameStream
    }

    deinit {
        frameStream.finish()
    }

    public func prepare(_ preparation: LectureCapturePreparation) async throws {
        guard !isRunning else { throw AVFoundationCaptureError.alreadyRunning }
        self.preparation = preparation
    }

    public func start() async throws {
        guard let preparation else { throw AVFoundationCaptureError.notPrepared }
        guard !isRunning else { throw AVFoundationCaptureError.alreadyRunning }
        let sink = try await makeWriterSink(for: preparation.session.id)
        await replaceActiveSink(with: sink)

        let requestedDeviceID = AudioDeviceID(preparation.deviceID)
        let candidateDeviceIDs: [AudioDeviceID]
        if let devices = try? CoreAudioInputDeviceProvider().inputDevices() {
            candidateDeviceIDs = Self.startAttemptDeviceIDs(
                requestedDeviceID: requestedDeviceID,
                devices: devices
            )
        } else {
            candidateDeviceIDs = [requestedDeviceID, requestedDeviceID]
        }

        for (index, deviceID) in candidateDeviceIDs.enumerated() {
            do {
                try configureAndStartEngine(deviceID: deviceID)
                recordingStartedAt = .now
                isRunning = true
                isPaused = false
                return
            } catch {
                await resetFailedEngineAttempt(sink: sink)
                if index < candidateDeviceIDs.count - 1 {
                    // Bluetooth and newly switched Core Audio routes can be
                    // visible before their input stream is ready to start.
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
        }

        await replaceActiveSink(with: nil)
        await storage.abandonActiveChunk(sessionID: preparation.session.id)
        throw AVFoundationCaptureError.audioEngineFailed
    }

    public func rollover(to nextPreparation: LectureCapturePreparation) async throws {
        guard isRunning,
              let currentPreparation = preparation,
              let startedAt = recordingStartedAt else {
            throw AVFoundationCaptureError.notPrepared
        }
        let nextSink = try await makeWriterSink(for: nextPreparation.session.id)
        let cutoverAt = ContinuousClock.now
        guard let currentSink = await replaceActiveSink(with: nextSink) else {
            await storage.abandonActiveChunk(sessionID: nextPreparation.session.id)
            throw AVFoundationCaptureError.notPrepared
        }
        preparation = nextPreparation
        recordingStartedAt = cutoverAt
        retiredWriterTasks.append(retireWriterSink(
            currentSink,
            sessionID: currentPreparation.session.id,
            duration: startedAt.duration(to: cutoverAt).seconds
        ))
    }

    public func pause() async throws {
        guard isRunning else { return }
        _ = try? await timeline?.record(.paused)
        engine.pause()
        isPaused = true
    }

    public func resume() async throws {
        guard isRunning, isPaused else { return }
        do {
            try engine.start()
            isPaused = false
            _ = try? await timeline?.record(.resumed)
        } catch {
            throw AVFoundationCaptureError.audioEngineFailed
        }
    }

    public func stop() async throws {
        guard isRunning, let preparation, let startedAt = recordingStartedAt else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try await flushWriterQueue()
        frameStream.finish()
        for task in retiredWriterTasks {
            _ = await task.result
        }
        retiredWriterTasks.removeAll(keepingCapacity: false)
        guard let sink = await currentActiveSink(), sink.audioFile != nil else {
            _ = try? await timeline?.record(.storageFailure)
            await storage.abandonActiveChunk(sessionID: preparation.session.id)
            await resetCaptureState()
            throw AVFoundationCaptureError.chunkWriteFailed
        }
        if sink.failure != nil {
            _ = try? await timeline?.record(.storageFailure)
            await storage.abandonActiveChunk(sessionID: preparation.session.id)
            await resetCaptureState()
            throw AVFoundationCaptureError.chunkWriteFailed
        }
        sink.audioFile = nil
        let duration = startedAt.duration(to: .now).seconds
        _ = try await storage.finalizeChunk(
            sessionID: preparation.session.id,
            chunkID: sink.chunkID,
            endsAt: duration
        )
        _ = try? await timeline?.record(.stopped)
        await resetCaptureState()
    }

    private func installTap(inputNode: AVAudioInputNode) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: Self.inputTapFormat
        ) { [writer] buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            let capturedAt = ContinuousClock.now
            let activity = AudioActivityMeter.measure(buffer: copy)
            writer.queue.async {
                guard let sink = writer.activeSink else { return }
                guard sink.failure == nil else { return }
                do {
                    let file: AVAudioFile
                    if let existingFile = sink.audioFile {
                        file = existingFile
                    } else {
                        let newFile = try AVAudioFile(
                            forWriting: sink.stagingURL,
                            settings: copy.format.settings
                        )
                        sink.audioFile = newFile
                        file = newFile
                    }
                    try file.write(from: copy)
                    writer.frameStream?.yield(
                        CapturedAudioFrame(
                            buffer: copy,
                            capturedAt: capturedAt,
                            activity: activity,
                            sessionID: sink.sessionID
                        )
                    )
                } catch {
                    sink.failure = error
                }
            }
        }
    }

    private func configureAndStartEngine(deviceID: AudioDeviceID) throws {
        let candidateEngine = AVAudioEngine()
        engine = candidateEngine
        let inputNode = candidateEngine.inputNode
        try setInputDevice(deviceID, inputNode: inputNode)
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AVFoundationCaptureError.invalidInputFormat
        }
        installTap(inputNode: inputNode)
        do {
            candidateEngine.prepare()
            try candidateEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            candidateEngine.stop()
            throw error
        }
    }

    private func makeWriterSink(for sessionID: SessionID) async throws -> CaptureWriterSink {
        let manifest = try await storage.loadManifest(sessionID: sessionID)
        let nextSequence = (manifest.lastCommittedChunk ?? -1) + 1
        let chunkID = try await storage.beginChunk(
            sessionID: sessionID,
            sequenceNumber: nextSequence,
            startsAt: 0,
            externalWriter: true
        )
        let stagingURL = try await storage.activeChunkStagingURL(
            sessionID: sessionID,
            chunkID: chunkID
        )
        return CaptureWriterSink(
            sessionID: sessionID,
            chunkID: chunkID,
            stagingURL: stagingURL
        )
    }

    private func retireWriterSink(
        _ sink: CaptureWriterSink,
        sessionID: SessionID,
        duration: TimeInterval
    ) -> Task<Void, Never> {
        Task { [storage, timeline] in
            if sink.failure != nil {
                _ = try? await timeline?.record(.storageFailure)
                await storage.abandonActiveChunk(sessionID: sessionID)
                sink.audioFile = nil
                sink.failure = nil
                return
            }
            guard sink.audioFile != nil else {
                await storage.abandonActiveChunk(sessionID: sessionID)
                return
            }
            sink.audioFile = nil
            do {
                _ = try await storage.finalizeChunk(
                    sessionID: sessionID,
                    chunkID: sink.chunkID,
                    endsAt: duration
                )
            } catch {
                _ = try? await timeline?.record(.storageFailure)
                await storage.abandonActiveChunk(sessionID: sessionID)
            }
        }
    }

    private func resetFailedEngineAttempt(sink: CaptureWriterSink) async {
        engine.stop()
        try? await flushWriterQueue()
        sink.audioFile = nil
        sink.failure = nil
        try? FileManager.default.removeItem(at: sink.stagingURL)
    }

    private func flushWriterQueue() async throws {
        await withCheckedContinuation { continuation in
            writer.queue.async { continuation.resume() }
        }
    }

    @discardableResult
    private func replaceActiveSink(with sink: CaptureWriterSink?) async -> CaptureWriterSink? {
        await withCheckedContinuation { continuation in
            writer.queue.async { [writer] in
                let previous = writer.activeSink
                writer.activeSink = sink
                continuation.resume(returning: previous)
            }
        }
    }

    private func currentActiveSink() async -> CaptureWriterSink? {
        await withCheckedContinuation { continuation in
            writer.queue.async { [writer] in
                continuation.resume(returning: writer.activeSink)
            }
        }
    }

    private func resetCaptureState() async {
        await replaceActiveSink(with: nil)
        recordingStartedAt = nil
        isRunning = false
        isPaused = false
    }

    private func setInputDevice(
        _ deviceID: AudioDeviceID,
        inputNode: AVAudioInputNode
    ) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AVFoundationCaptureError.deviceSelectionFailed(kAudio_ParamError)
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AVFoundationCaptureError.deviceSelectionFailed(status)
        }
    }
}

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else {
                continue
            }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
