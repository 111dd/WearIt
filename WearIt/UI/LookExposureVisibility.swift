import SwiftUI
import os

private struct ExposureSurfaceActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var exposureSurfaceActive: Bool {
        get { self[ExposureSurfaceActiveKey.self] }
        set { self[ExposureSurfaceActiveKey.self] = newValue }
    }
}

/// Attach to the garment region, not to the day header or a lazy card's onAppear.
private struct LookExposureVisibility: ViewModifier {
    let prototype: LookExposure?
    let enabled: Bool
    @Environment(\.exposureSurfaceActive) private var surfaceActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var inViewport = false
    @State private var mounted = false

    private var canRecord: Bool {
        enabled && surfaceActive && mounted && inViewport && scenePhase == .active
    }

    private var taskKey: String {
        canRecord ? (prototype?.observationIdentity ?? "empty") : "inactive"
    }

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.5) { inViewport = $0 }
            .onAppear { mounted = true }
            .onDisappear { mounted = false; inViewport = false }
            .task(id: taskKey) {
                guard canRecord, let prototype else { return }
                let session = ExposureLog.shared.sessionToken()
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                    try Task.checkCancellation()
                    guard canRecord, taskKey == prototype.observationIdentity else { return }
                    _ = try await ExposureLog.shared.record(prototype.observed(at: Date()), session: session)
                } catch is CancellationError {
                    // Leaving the viewport, changing tabs/look, or backgrounding cancels dwell.
                } catch {
                    Logger(subsystem: "com.dordavid.WearIt", category: "ExposureLog")
                        .error("Visible look could not be recorded: \(error.localizedDescription, privacy: .public)")
                }
            }
    }
}

extension View {
    func recordLookExposure(_ prototype: LookExposure?, enabled: Bool = true) -> some View {
        modifier(LookExposureVisibility(prototype: prototype, enabled: enabled))
    }
}
