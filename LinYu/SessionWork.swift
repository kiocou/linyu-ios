import Foundation

enum SessionWork {
    @TaskLocal static var generation: UUID?
    static func isCurrent(_ expected: UUID) -> Bool {
        !Task.isCancelled && Session.shared.isLoggedIn && expected == Session.shared.requestGeneration
    }
}

/// 对照 Android sessionJob：子任务继承登录代次，退出时一起取消。
@MainActor final class SessionWorkScope {
    let generation = Session.shared.requestGeneration
    private var stopped = false
    private var cancellations: [UUID: () -> Void] = [:]
    var isCurrent: Bool { !stopped && SessionWork.isCurrent(generation) }

    func run<T>(fallback: T, _ operation: @escaping @MainActor () async -> T) async -> T {
        guard isCurrent else { return fallback }
        let id = UUID()
        let task = Task { @MainActor in
            await SessionWork.$generation.withValue(generation) {
                guard self.isCurrent else { return fallback }
                return await operation()
            }
        }
        cancellations[id] = { task.cancel() }
        defer { cancellations[id] = nil }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func cancel() {
        stopped = true
        let pending = Array(cancellations.values)
        cancellations.removeAll()
        for cancel in pending { cancel() }
    }
}
