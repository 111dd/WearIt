import Foundation
import os

/// Serial disk worker with synchronous reset/export boundaries for AccountDataService.
/// All mutable state is private to `queue`; no live SwiftData objects cross this boundary.
/// Unlike an actor-only API, reset completes in the same UI turn as account deletion.
final class ExposureLog: @unchecked Sendable {
    struct Provenance: Codable, Sendable {
        let origin: LookExposure.Origin
        let updatedAt: Date
    }
    struct Snapshot: Codable, Sendable {
        var formatVersion = 1
        var trackingStartedAt: Date?
        /// Coverage is per profile; a new profile must not inherit another profile's observation window.
        var trackingStartedAtByProfile: [String: Date] = [:]
        var historyTruncatedBefore: Date?
        var records: [LookExposure] = []
        var provenance: [String: Provenance] = [:]

        private enum CodingKeys: String, CodingKey {
            case formatVersion, trackingStartedAt, trackingStartedAtByProfile
            case historyTruncatedBefore, records, provenance
        }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decode(Int.self, forKey: .formatVersion)
            trackingStartedAt = try values.decodeIfPresent(Date.self, forKey: .trackingStartedAt)
            trackingStartedAtByProfile = try values.decodeIfPresent([String: Date].self, forKey: .trackingStartedAtByProfile) ?? [:]
            historyTruncatedBefore = try values.decodeIfPresent(Date.self, forKey: .historyTruncatedBefore)
            records = try values.decode([LookExposure].self, forKey: .records)
            provenance = try values.decodeIfPresent([String: Provenance].self, forKey: .provenance) ?? [:]
        }
    }
    enum StorageError: Error { case unsupportedFormat, invalidExposure }

    static let shared = ExposureLog(fileURL: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("WearItExposureLog/log.json"))

    private let queue = DispatchQueue(label: "com.dordavid.WearIt.exposure-log", qos: .utility)
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.dordavid.WearIt", category: "ExposureLog")
    private var state = Snapshot()
    private var loaded = false
    private var generation = UUID()
    private var revision = 0
    private var dirty = false
    private var pendingWrite: DispatchWorkItem?
    private let maximumRecords = 10_000

    init(fileURL: URL) { self.fileURL = fileURL }

    /// Capture before starting a dwell task. An old task cannot repopulate a deleted account.
    func sessionToken() -> UUID { queue.sync { generation } }

    /// Stage 2 calls this only after real visibility/interaction is established.
    /// It returns the existing identity on duplicate display, for feedback attribution.
    func record(_ exposure: LookExposure, session: UUID, now: Date = Date()) async throws -> UUID? {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard session == self.generation else { continuation.resume(returning: nil); return }
                    let id = try self.append(exposure, now: now)
                    continuation.resume(returning: id)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Provenance is not an impression. Background generation may call this safely.
    func rememberOrigin(_ exposure: LookExposure, session: UUID) {
        queue.async {
            guard session == self.generation else { return }
            do {
                let now = Date()
                try self.load(now: now)
                self.state.provenance[exposure.provenanceKey] = Provenance(origin: exposure.origin, updatedAt: now)
                self.prune(now: now)
                self.dirty = true
                self.scheduleWrite()
            } catch { self.logger.error("Exposure provenance unavailable: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Called only for an explicit action on the exact current look, never for widget preparation.
    /// Prefer the current day's actual dwell; quick actions get distinct evidence.
    func interaction(_ prototype: LookExposure) -> UUID? {
        queue.sync {
            do {
                let now = Date()
                let interaction = prototype.observed(at: now, evidence: .explicitInteraction)
                try load(now: now)
                if let seen = state.records.last(where: {
                    $0.decisionKey == interaction.decisionKey && $0.evidence == .visibleDwell
                }) { return seen.id }
                return try append(interaction, now: now)
            } catch {
                logger.error("Exposure interaction unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private func append(_ proposed: LookExposure, now: Date) throws -> UUID {
        try load(now: now)
        guard !proposed.slots.isEmpty, ["day", "evening"].contains(proposed.lookTime),
              proposed.firstShownAt <= now,
              proposed.firstShownAt >= now.addingTimeInterval(-180 * 86_400) else {
            throw StorageError.invalidExposure
        }
        prune(now: now)
        if let existing = state.records.first(where: { $0.deduplicationKey == proposed.deduplicationKey }) {
            return existing.id
        }
        var exposure = proposed
        if exposure.origin == .unknown, let remembered = state.provenance[exposure.provenanceKey] {
            exposure.origin = remembered.origin
        }
        // An interaction is not evidence that timed-visibility coverage has started.
        if exposure.evidence == .visibleDwell {
            state.trackingStartedAt = state.trackingStartedAt ?? now
            let key = exposure.profileID.uuidString
            state.trackingStartedAtByProfile[key] = state.trackingStartedAtByProfile[key] ?? now
        }
        state.records.append(exposure)
        prune(now: now)
        dirty = true
        scheduleWrite()
        return exposure.id
    }

    /// Includes queued and debounced records. Disk failures/corruption propagate, never masquerade as empty history.
    func snapshot(now: Date = Date()) throws -> Snapshot {
        try queue.sync {
            try load(now: now)
            prune(now: now)
            return state
        }
    }

    /// Called on background; serialization and atomic writes run on the worker queue.
    func flush() {
        queue.async {
            self.pendingWrite?.cancel()
            self.pendingWrite = nil
            self.writeLoggingFailure()
        }
    }

    /// No await: completes before deleted models can render or a new account can begin recording.
    func reset() throws {
        try queue.sync {
            generation = UUID()
            revision += 1
            pendingWrite?.cancel()
            pendingWrite = nil
            state = Snapshot()
            loaded = true
            dirty = false
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func load(now: Date) throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard decoded.formatVersion == 1 else { throw StorageError.unsupportedFormat }
            state = decoded
        }
        loaded = true
        prune(now: now)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-180 * 86_400)
        let oldCount = state.records.count
        let oldProvenanceCount = state.provenance.count
        state.provenance = state.provenance.filter { $0.value.updatedAt >= cutoff }
        if state.provenance.count > maximumRecords {
            let keep = state.provenance.sorted {
                if $0.value.updatedAt != $1.value.updatedAt { return $0.value.updatedAt > $1.value.updatedAt }
                return $0.key < $1.key
            }.prefix(maximumRecords)
            state.provenance = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        state.records.removeAll { $0.firstShownAt < cutoff }
        state.records.sort {
            if $0.firstShownAt != $1.firstShownAt { return $0.firstShownAt < $1.firstShownAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if state.records.count > maximumRecords {
            let removed = state.records.count - maximumRecords
            let boundary = state.records[removed - 1].firstShownAt
            state.historyTruncatedBefore = max(state.historyTruncatedBefore ?? boundary, boundary)
            state.records.removeFirst(removed)
        }
        if state.records.count != oldCount || state.provenance.count != oldProvenanceCount { dirty = true }
    }

    private func scheduleWrite() {
        revision += 1
        let expectedRevision = revision
        let expectedGeneration = generation
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration, self.revision == expectedRevision else { return }
            self.writeLoggingFailure()
        }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func writeLoggingFailure() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
            dirty = false
        } catch {
            // Keep the dirty in-memory snapshot available for export and retry on the next flush.
            logger.error("Exposure log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
