import QuartzCore
import UIKit

/// ProMotion (variable refresh rate) support for WearIt.
///
/// Apple docs:
/// https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays
///
/// Requirements for >60Hz on iPhone:
/// - `CADisableMinimumFrameDurationOnPhone = true` in Info.plist (already set)
/// - Prefer SwiftUI / UIKit / CAAnimation (system frame pacing)
/// - Avoid live heavy `.blur` during scroll
/// - For custom `CADisplayLink` / `CAAnimation`, apply `preferredFrameRateRange`
enum ProMotionSupport {
    /// Call once at launch. Info.plist unlocks the range; this tunes UIKit chrome.
    static func install() {
        // Smooth deceleration feels better on 120Hz panels.
        UIScrollView.appearance().decelerationRate = .normal

        // Keep layer animations on the display clock (default, but explicit).
        CATransaction.setDisableActions(false)
    }

    /// High-impact transitions (sheet present, hero expand, tab crossfade).
    static var highImpactFrameRateRange: CAFrameRateRange {
        CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    }

    /// Default system pacing — fine for most UI.
    static var standardFrameRateRange: CAFrameRateRange {
        .default
    }

    /// Apply preferred range to a display link used for custom drawing.
    static func configure(_ displayLink: CADisplayLink, highImpact: Bool = false) {
        displayLink.preferredFrameRateRange = highImpact
            ? highImpactFrameRateRange
            : standardFrameRateRange
    }

    /// Apply preferred range to a Core Animation object when custom timing is needed.
    static func configure(_ animation: CAAnimation, highImpact: Bool = false) {
        animation.preferredFrameRateRange = highImpact
            ? highImpactFrameRateRange
            : standardFrameRateRange
    }
}
