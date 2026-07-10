//
//  CollapsingNavBar.swift
//  WearIt
//
//  Compact inline nav title + native swipe-to-hide (UIKit).
//  Avoids SwiftUI toolbarVisibility toggling, which can freeze Liquid Glass.
//

import SwiftUI
import UIKit

/// Enables `UINavigationController.hidesBarsOnSwipe` so the top bar
/// slides away when scrolling down and returns when scrolling up.
private struct HideBarsOnSwipeConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            Self.apply(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            Self.apply(from: uiView)
        }
    }

    private static func apply(from view: UIView) {
        var responder: UIResponder? = view
        while let current = responder {
            if let vc = current as? UIViewController,
               let nav = vc.navigationController {
                nav.hidesBarsOnSwipe = true
                nav.navigationBar.isTranslucent = true
                nav.navigationBar.backgroundColor = .clear
                nav.view.backgroundColor = .clear
                return
            }
            responder = current.next
        }
    }

    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

extension View {
    /// Compact inline title; top bar hides on scroll-down via UIKit.
    func minimalCollapsingNavBar() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .background { HideBarsOnSwipeConfigurator() }
    }
}
