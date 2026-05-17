import Foundation
import NIOCore

/// One per active SSE connection. The router creates a writer on GET,
/// hands it to MCPSessionRegistry.attachSSE, and uses writer.stream as
/// the AsyncSequence backing the ResponseBody.
///
/// AsyncStream supports only ONE consumer — the ResponseBody is that
/// single consumer. Disconnect detection happens via onTermination, not
/// by spawning a second reader task.
final class MCPSSEWriter: @unchecked Sendable {
    private let continuation: AsyncStream<ByteBuffer>.Continuation
    let stream: AsyncStream<ByteBuffer>
    private var closed: Bool = false
    private let lock = NSLock()
    private var onCloseCallback: (@Sendable () -> Void)?

    init() {
        var capturedContinuation: AsyncStream<ByteBuffer>.Continuation!
        self.stream = AsyncStream<ByteBuffer> { cont in
            capturedContinuation = cont
        }
        self.continuation = capturedContinuation
        self.continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.closed = true
            let cb = self.onCloseCallback
            self.lock.unlock()
            cb?()
        }
    }

    func setOnClose(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyClosed = closed
        if !alreadyClosed {
            onCloseCallback = callback
        }
        lock.unlock()
        if alreadyClosed { callback() }
    }

    func send(jsonRPC: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let frame = "data: \(jsonRPC)\n\n"
        var buffer = ByteBufferAllocator().buffer(capacity: frame.utf8.count)
        buffer.writeString(frame)
        continuation.yield(buffer)
    }

    func sendKeepAlive() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let frame = ": keepalive\n\n"
        var buffer = ByteBufferAllocator().buffer(capacity: frame.utf8.count)
        buffer.writeString(frame)
        continuation.yield(buffer)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        continuation.finish()
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }
}
