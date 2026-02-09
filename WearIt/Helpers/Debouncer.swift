//
//  Debouncer.swift
//  WearIt
//
//  Runs an action once after a quiet period; rescheduling cancels the previous run.
//

import Foundation

@MainActor
final class Debouncer {
    private let interval: TimeInterval
    private var workItem: DispatchWorkItem?
    private let queue: DispatchQueue

    init(interval: TimeInterval, queue: DispatchQueue = .main) {
        self.interval = interval
        self.queue = queue
    }

    /// Schedule the action. If already scheduled, resets the timer.
    func schedule(action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            action()
            self?.workItem = nil
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Run the pending action immediately and cancel any scheduled run.
    func flush() {
        workItem?.cancel()
        workItem = nil
    }
}
