//
//  HorizontalSwipeGesture.swift
//  WearIt
//
//  A sideways swipe that lives happily inside a vertical ScrollView.
//  A SwiftUI DragGesture there either blocks scrolling or gets cancelled by the
//  scroll view on iOS 18, so this bridges a UIKit pan that fails as soon as the
//  finger moves more vertically than horizontally. Taps, context menus and
//  drag-and-drop on the content keep working.
//

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool = true
    /// Horizontal travel in the view's local space (RTL-aware).
    let onChanged: (CGFloat) -> Void
    /// Final travel and the absolute horizontal speed (points per second).
    let onEnded: (_ travel: CGFloat, _ speed: CGFloat) -> Void
    let onCancelled: () -> Void

    final class Coordinator {
        var startX: CGFloat = 0
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanGestureRecognizer {
        let recognizer = HorizontalPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        let x = context.converter.localLocation.x
        switch recognizer.state {
        case .began:
            context.coordinator.startX = x
        case .changed:
            onChanged(x - context.coordinator.startX)
        case .ended:
            let speed = abs(recognizer.velocity(in: recognizer.view).x)
            onEnded(x - context.coordinator.startX, speed)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }
}

/// Pan that only begins for clearly horizontal movement.
final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    private var startPoint: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if startPoint == nil {
            startPoint = touches.first?.location(in: view)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let startPoint, let point = touches.first?.location(in: view) {
            let dx = abs(point.x - startPoint.x)
            let dy = abs(point.y - startPoint.y)
            if dy > 6, dy > dx {
                // Vertical: let the scroll view have it.
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        startPoint = nil
    }
}
