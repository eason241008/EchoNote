import Foundation

public struct RecordingPolicyAcknowledgement: Codable, Equatable, Sendable {
    public let version: Int
    public let acknowledgedAt: Date

    public init(version: Int, acknowledgedAt: Date) {
        self.version = version
        self.acknowledgedAt = acknowledgedAt
    }
}

@MainActor
public final class RecordingPolicyStore {
    public static let currentVersion = 1

    private let defaults: UserDefaults
    private let key = "lecture-assistant.recording-policy-acknowledgement"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func acknowledgement() -> RecordingPolicyAcknowledgement? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecordingPolicyAcknowledgement.self, from: data)
    }

    public func acknowledgeCurrentPolicy(at date: Date = Date()) throws {
        let acknowledgement = RecordingPolicyAcknowledgement(
            version: Self.currentVersion,
            acknowledgedAt: date
        )
        defaults.set(try JSONEncoder().encode(acknowledgement), forKey: key)
    }

    public func isCurrentPolicyAcknowledged() -> Bool {
        acknowledgement()?.version == Self.currentVersion
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }
}

public enum RecordingStartGateError: LocalizedError, Equatable {
    case policyAcknowledgementRequired
    case preflightNotReady([CapturePreflightIssue])

    public var errorDescription: String? {
        switch self {
        case .policyAcknowledgementRequired:
            return "Accept the recording policy before starting capture."
        case .preflightNotReady:
            return "Microphone capture preflight is not ready."
        }
    }
}

public struct RecordingStartGate {
    public init() {}

    public func validate(
        policyAcknowledged: Bool,
        preflight: CapturePreflightResult
    ) throws {
        guard policyAcknowledged else {
            throw RecordingStartGateError.policyAcknowledgementRequired
        }
        guard preflight.isReady else {
            throw RecordingStartGateError.preflightNotReady(preflight.issues)
        }
    }
}
