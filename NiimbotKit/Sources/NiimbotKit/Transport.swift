import Foundation

/// A byte pipe to a printer (Bluetooth LE, or a recorded dump in tests).
@MainActor
public protocol NiimbotTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
    func write(_ data: Data) async throws
    func close()
}

/// Serialises request/response exchanges so heartbeats never interleave with other commands.
@MainActor
final class AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
        defer {
            if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// A pending response. Registered before the request is written so a fast reply cannot be missed.
@MainActor
final class ResponseWaiter {
    let ids: Set<UInt8>
    private var result: Result<NiimbotPacket, Error>?
    private var continuation: CheckedContinuation<NiimbotPacket, Error>?

    init(ids: Set<UInt8>) { self.ids = ids }

    var isDone: Bool { result != nil }

    func complete(_ r: Result<NiimbotPacket, Error>) {
        guard result == nil else { return }
        result = r
        continuation?.resume(with: r)
        continuation = nil
    }

    func value() async throws -> NiimbotPacket {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
