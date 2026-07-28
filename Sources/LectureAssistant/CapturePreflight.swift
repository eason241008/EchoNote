import AVFoundation
import CoreAudio
import Foundation

public enum MicrophoneAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized

    init(status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .authorized: self = .authorized
        @unknown default: self = .denied
        }
    }
}

public protocol MicrophoneAuthorizationProviding: Sendable {
    func status() -> MicrophoneAuthorization
    func requestAccess() async -> Bool
}

public struct SystemMicrophoneAuthorizationProvider: MicrophoneAuthorizationProviding {
    public init() {}

    public func status() -> MicrophoneAuthorization {
        MicrophoneAuthorization(status: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let isDefault: Bool

    public init(id: AudioDeviceID, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum AudioInputDeviceError: LocalizedError, Equatable {
    case enumerationFailed(OSStatus)

    public var errorDescription: String? {
        "Available microphone devices could not be read."
    }
}

public protocol AudioInputDeviceProviding: Sendable {
    func inputDevices() throws -> [AudioInputDevice]
}

public struct CoreAudioInputDeviceProvider: AudioInputDeviceProviding {
    public init() {}

    public func inputDevices() throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { throw AudioInputDeviceError.enumerationFailed(status) }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { throw AudioInputDeviceError.enumerationFailed(status) }

        let defaultDevice = try defaultInputDevice()
        return try deviceIDs.compactMap { deviceID in
            guard try inputChannelCount(deviceID: deviceID) > 0 else { return nil }
            return AudioInputDevice(
                id: deviceID,
                name: try deviceName(deviceID: deviceID),
                isDefault: deviceID == defaultDevice
            )
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else { throw AudioInputDeviceError.enumerationFailed(status) }
        return deviceID
    }

    private func inputChannelCount(deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { throw AudioInputDeviceError.enumerationFailed(status) }
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { pointer.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        guard status == noErr else { throw AudioInputDeviceError.enumerationFailed(status) }
        let list = UnsafeMutableAudioBufferListPointer(
            pointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func deviceName(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "Unknown Input" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr else { throw AudioInputDeviceError.enumerationFailed(status) }
        return name as String
    }
}

public struct AudioActivityLevel: Equatable, Sendable {
    public let rootMeanSquare: Float
    public let decibels: Float

    public init(rootMeanSquare: Float, decibels: Float) {
        self.rootMeanSquare = rootMeanSquare
        self.decibels = decibels
    }
}

public enum AudioActivityMeter {
    public static func measure(buffer: AVAudioPCMBuffer) -> AudioActivityLevel {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.channelCount > 0 else {
            return AudioActivityLevel(rootMeanSquare: 0, decibels: -80)
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }
        let rootMeanSquare = sqrt(sum / Float(frameCount * channelCount))
        let decibels = rootMeanSquare > 0 ? max(-80, 20 * log10(rootMeanSquare)) : -80
        return AudioActivityLevel(rootMeanSquare: rootMeanSquare, decibels: decibels)
    }
}

public enum CapturePreflightIssue: Equatable, Sendable {
    case microphonePermissionRequired
    case microphonePermissionDenied
    case selectedDeviceUnavailable
    case storageUnavailable
    case transcriptionModelUnavailable
}

public struct CapturePreflightResult: Equatable, Sendable {
    public let authorization: MicrophoneAuthorization
    public let devices: [AudioInputDevice]
    public let selectedDevice: AudioInputDevice?
    public let issues: [CapturePreflightIssue]

    public var isReady: Bool { issues.isEmpty }

    public init(
        authorization: MicrophoneAuthorization,
        devices: [AudioInputDevice],
        selectedDevice: AudioInputDevice?,
        issues: [CapturePreflightIssue]
    ) {
        self.authorization = authorization
        self.devices = devices
        self.selectedDevice = selectedDevice
        self.issues = issues
    }
}

public struct CapturePreflightService {
    private let authorizationProvider: any MicrophoneAuthorizationProviding
    private let deviceProvider: any AudioInputDeviceProviding
    private let fileManager: FileManager

    public init(
        authorizationProvider: any MicrophoneAuthorizationProviding = SystemMicrophoneAuthorizationProvider(),
        deviceProvider: any AudioInputDeviceProviding = CoreAudioInputDeviceProvider(),
        fileManager: FileManager = .default
    ) {
        self.authorizationProvider = authorizationProvider
        self.deviceProvider = deviceProvider
        self.fileManager = fileManager
    }

    public func evaluate(
        selectedDeviceID: AudioDeviceID?,
        storageRootURL: URL,
        transcriptionModelReady: Bool
    ) throws -> CapturePreflightResult {
        let authorization = authorizationProvider.status()
        let devices = try deviceProvider.inputDevices()
        let selectedDevice = selectedDeviceID.flatMap { id in devices.first { $0.id == id } }
            ?? devices.first { $0.isDefault }
        var issues: [CapturePreflightIssue] = []
        switch authorization {
        case .notDetermined: issues.append(.microphonePermissionRequired)
        case .denied, .restricted: issues.append(.microphonePermissionDenied)
        case .authorized: break
        }
        if selectedDevice == nil { issues.append(.selectedDeviceUnavailable) }
        if !isWritable(directoryURL: storageRootURL) { issues.append(.storageUnavailable) }
        if !transcriptionModelReady { issues.append(.transcriptionModelUnavailable) }
        return CapturePreflightResult(
            authorization: authorization,
            devices: devices,
            selectedDevice: selectedDevice,
            issues: issues
        )
    }

    private func isWritable(directoryURL: URL) -> Bool {
        let probeURL = directoryURL.appendingPathComponent(".write-probe-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data().write(to: probeURL, options: .atomic)
            try fileManager.removeItem(at: probeURL)
            return true
        } catch {
            try? fileManager.removeItem(at: probeURL)
            return false
        }
    }
}
