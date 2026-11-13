import Foundation
import os

/// Shares preparation and ranking between Shopping and Stats. Only value results are cached.
@MainActor
final class ShopRankingCoordinator {
    static let shared = ShopRankingCoordinator()
    private static let lifetime: TimeInterval = 60
    private static let cacheLimit = 2

    private struct Cached {
        let result: ShopRankingWorker.Result
        let completedAt: Date
    }
    private struct Pending {
        let id: UUID
        let task: Task<ShopRankingWorker.Result, Never>
        var waiters: Set<UUID>
    }
    private var cached: [Int: Cached] = [:]
    private var pending: [Int: Pending] = [:]

    func result(key: Int, prepare: () -> ShopRankingWorker.Request) async -> ShopRankingWorker.Result {
        guard !Task.isCancelled else { return .init() }
        let now = Date()
        cached = cached.filter {
            let age = now.timeIntervalSince($0.value.completedAt)
            return age >= 0 && age < Self.lifetime
        }
        if let entry = cached[key] {
            WearItPerformance.shoppingSignposter.emitEvent("result-cache-hit")
            return entry.result
        }

        let waiterID = UUID()
        let job: Pending
        if var existing = pending[key] {
            existing.waiters.insert(waiterID)
            pending[key] = existing
            job = existing
            WearItPerformance.shoppingSignposter.emitEvent("shared-ranking")
        } else {
            // Snapshot live models synchronously, before the first suspension point.
            let interval = WearItPerformance.shoppingSignposter.beginInterval("snapshot",
                id: WearItPerformance.shoppingSignposter.makeSignpostID())
            let request = prepare()
            WearItPerformance.shoppingSignposter.endInterval("snapshot", interval)
            let task = Task { await ShopRankingWorker.shared.rank(request) }
            job = Pending(id: UUID(), task: task, waiters: [waiterID])
            pending[key] = job
        }

        let result = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            Task { @MainActor in
                self.release(waiterID, key: key, jobID: job.id)
            }
        }
        if pending[key]?.id == job.id {
            pending[key] = nil
            if !job.task.isCancelled {
                cached[key] = Cached(result: result, completedAt: Date())
                if cached.count > Self.cacheLimit,
                   let oldest = cached.min(by: { $0.value.completedAt < $1.value.completedAt })?.key {
                    cached[oldest] = nil
                }
            }
        }
        return Task.isCancelled || job.task.isCancelled ? .init() : result
    }

    /// Cancel an abandoned request only after its last screen has stopped waiting.
    private func release(_ waiterID: UUID, key: Int, jobID: UUID) {
        guard var job = pending[key], job.id == jobID else { return }
        job.waiters.remove(waiterID)
        if job.waiters.isEmpty {
            pending[key] = nil
            job.task.cancel()
        } else {
            pending[key] = job
        }
    }

    func reset() {
        for job in pending.values { job.task.cancel() }
        pending.removeAll()
        cached.removeAll()
        Task { await ShopRankingWorker.shared.reset() }
    }
}
