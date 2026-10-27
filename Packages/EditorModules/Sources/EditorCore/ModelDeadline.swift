import Foundation

/// El modelo no respondió dentro del plazo.
public struct ModelDeadlineExceeded: Error, Equatable {}

/// Espera `operation` como máximo `timeout` y vuelve en cuanto vence el plazo
/// o se cancela quien espera. Un `withThrowingTaskGroup` no sirve para esto:
/// al salir espera a sus hijos, y una generación que ignore la cancelación
/// alargaría la espera hasta que termine sola.
/// La operación abandonada recibe la cancelación y su resultado se descarta.
public func withModelDeadline<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    let work = Task { try await operation() }
    let waiter = Task { race.finish(await work.result) }
    let timer = Task {
        try await Task.sleep(for: timeout)
        race.finish(.failure(ModelDeadlineExceeded()))
    }
    defer {
        work.cancel()
        waiter.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { race.attach($0) }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Primer resultado gana; el resto se ignora. El candado cubre que la
/// cancelación llegue antes de que exista la continuación.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?

    func attach(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ outcome: Result<T, any Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}
