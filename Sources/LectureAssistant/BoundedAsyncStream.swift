import Foundation

public final class BoundedAsyncStream<Element: Sendable>: @unchecked Sendable {
    public let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let lock = NSLock()
    private var droppedElementCount = 0

    public init(limit: Int) {
        var capturedContinuation: AsyncStream<Element>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(max(1, limit))) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation!
    }

    @discardableResult
    public func yield(_ element: Element) -> AsyncStream<Element>.Continuation.YieldResult {
        let result = continuation.yield(element)
        if case .dropped = result {
            lock.withLock { droppedElementCount += 1 }
        }
        return result
    }

    public func finish() {
        continuation.finish()
    }

    public var droppedCount: Int {
        lock.withLock { droppedElementCount }
    }
}
