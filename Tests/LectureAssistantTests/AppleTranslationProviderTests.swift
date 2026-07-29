import Foundation
import XCTest
@testable import LectureAssistant

private actor StubAppleTranslationSession: AppleTranslationSessionServing {
    enum Failure: LocalizedError {
        case preparation

        var errorDescription: String? { "Language preparation failed." }
    }

    private let preparationError: Error?
    private(set) var receivedRequests: [AppleTranslationRequest] = []

    init(preparationError: Error? = nil) {
        self.preparationError = preparationError
    }

    func prepareTranslation() async throws {
        if let preparationError { throw preparationError }
    }

    func translations(
        from requests: [AppleTranslationRequest]
    ) async throws -> [AppleTranslationResult] {
        receivedRequests = requests
        return requests.map {
            AppleTranslationResult(
                targetText: "中文：\($0.sourceText)",
                clientIdentifier: $0.clientIdentifier
            )
        }
    }

    func requests() -> [AppleTranslationRequest] { receivedRequests }
}

final class AppleTranslationProviderTests: XCTestCase {
    func testUsesOnDeviceMetadataAndPreservesRevisionLinks() async throws {
        let provider = AppleTranslationProvider()
        let session = StubAppleTranslationSession()
        let first = TranscriptRevisionID()
        let second = TranscriptRevisionID()
        let request = try SimplifiedChineseTranslationRequest(segments: [
            TranslationSourceSegment(revisionID: first, text: "First sentence"),
            TranslationSourceSegment(revisionID: second, text: "Second sentence"),
        ])
        let runTask = Task { await provider.run(session: session) }

        let response = try await provider.translate(request)
        runTask.cancel()

        XCTAssertEqual(provider.providerID, "apple-translation")
        XCTAssertEqual(provider.model, "system-on-device")
        XCTAssertEqual(response.translations.map(\.revisionID), [first, second])
        XCTAssertEqual(response.translations.map(\.text), ["中文：First sentence", "中文：Second sentence"])
        let requests = await session.requests()
        XCTAssertEqual(requests.map(\.sourceText), ["First sentence", "Second sentence"])
        XCTAssertEqual(requests.map(\.clientIdentifier), [
            first.rawValue.uuidString,
            second.rawValue.uuidString,
        ])
    }

    func testPreparationFailurePublishesUnavailableAndRejectsTranslations() async throws {
        let provider = AppleTranslationProvider()
        let session = StubAppleTranslationSession(
            preparationError: StubAppleTranslationSession.Failure.preparation
        )
        let stateTask = Task { () -> AppleTranslationServiceState? in
            for await state in provider.states {
                if case .unavailable = state { return state }
            }
            return nil
        }

        let runTask = Task { await provider.run(session: session) }
        let state = await stateTask.value
        let request = try SimplifiedChineseTranslationRequest(segments: [
            TranslationSourceSegment(
                revisionID: TranscriptRevisionID(),
                text: "Lecture sentence"
            ),
        ])

        do {
            _ = try await provider.translate(request)
            XCTFail("Expected preparation failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Language preparation failed.")
        }
        XCTAssertEqual(state, .unavailable("Language preparation failed."))
        runTask.cancel()
    }
}
