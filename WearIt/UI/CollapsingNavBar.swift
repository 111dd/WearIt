//
//  CollapsingNavBar.swift
//  WearIt
//
//  Compact inline nav title + native swipe-to-hide (UIKit).
//  Avoids SwiftUI toolbarVisibility toggling, which can freeze Liquid Glass.
//

import SwiftUI
import UIKit

/// Sets `UINavigationController.hidesBarsOnSwipe` so the top bar slides away
/// when scrolling down and returns when scrolling up.
///
/// The flag lives on the navigation controller, which is shared with every
/// screen pushed on top, so a pushed screen turns it off — otherwise its back
/// button disappears after a short scroll and only scrolling up brings it back.
/// The responder walk runs on attach and whenever the wanted value changes,
/// never on every SwiftUI update: during scrolling that was main-thread work
/// for nothing.
private struct HidesBarsOnSwipe: UIViewRepresentable {
    let isEnabled: Bool

    final class Coordinator {
        var applied: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        view.isUserInteractionEnabled = false
        let isEnabled = isEnabled
        view.onReattach = { [weak view] in
            guard let view else { return }
            Self.apply(isEnabled, from: view)
        }
        applyIfNeeded(from: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        applyIfNeeded(from: uiView, coordinator: context.coordinator)
    }

    private func applyIfNeeded(from view: UIView, coordinator: Coordinator) {
        guard coordinator.applied != isEnabled else { return }
        coordinator.applied = isEnabled
        Self.apply(isEnabled, from: view)
    }

    private static func apply(_ isEnabled: Bool, from view: UIView) {
        DispatchQueue.main.async {
            var responder: UIResponder? = view
            while let current = responder {
                if let vc = current as? UIViewController,
                   let nav = vc.navigationController {
                    nav.hidesBarsOnSwipe = isEnabled
                    if !isEnabled {
                        nav.setNavigationBarHidden(false, animated: false)
                    }
                    nav.navigationBar.isTranslucent = true
                    nav.navigationBar.backgroundColor = .clear
                    nav.view.backgroundColor = .clear
                    return
                }
                responder = current.next
            }
        }
    }

    private final class PassthroughView: UIView {
        /// Re-assert on re-attach: popping a pushed screen brings a root screen
        /// back, and it has to take the flag back from the screen that left.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            onReattach?()
        }

        var onReattach: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

private struct CollapsingNavBarModifier: ViewModifier {
    let hidesOnSwipe: Bool

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .background { HidesBarsOnSwipe(isEnabled: hidesOnSwipe) }
    }
}

extension View {
    /// Compact inline title; top bar hides on scroll-down via UIKit.
    /// For a screen at the root of its own navigation stack (a tab).
    func minimalCollapsingNavBar() -> some View {
        modifier(CollapsingNavBarModifier(hidesOnSwipe: true))
    }

    /// Compact inline title with the bar always visible.
    /// For a pushed screen, which needs its back button to stay put.
    func compactNavBar() -> some View {
        modifier(CollapsingNavBarModifier(hidesOnSwipe: false))
    }
}
