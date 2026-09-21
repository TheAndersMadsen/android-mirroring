import SwiftUI

/// Layout and animation constants extracted from the iPhone Mirroring
/// binary's constant pool (see research/iphone-mirroring-re.md).
/// These are the exact values Apple uses, found via binary RE.
enum ChromeConstants {
    // Device screen (iPhone 14/15 reference: 390×844pt)
    static let referenceWidth: CGFloat = 390
    static let referenceHeight: CGFloat = 844

    // Bezel / chrome
    static let bezelWidth: CGFloat = 14          // exact match: 14.0 in constant pool
    static let cornerRadius: CGFloat = 54        // exact match: 54.0 in constant pool
    static let smallCornerRadius: CGFloat = 4
    static let shadowRadius: CGFloat = 5

    // Animations (exact values from constant pool)
    static let chromeRevealDuration: Double = 0.4
    static let standardAnimation: Double = 0.5
    static let blurAnimation: Double = 0.8
    static let blurRemovalAnimation: Double = 0.75
    static let errorAnimationDelay: Double = 0.2
    static let springDampingSubtle: Double = 0.95
    static let springDampingBouncy: Double = 0.85
    static let springBounce: Double = 1.18

    // Opacity
    static let chromeOpacity: Double = 0.77

    // Window sizing
    static let defaultWindowHeight: CGFloat = 640
    static let onboardingWindowHeight: CGFloat = 640
    static let onboardingWindowWidth: CGFloat = 360

    // Settle timeout
    static let settleTimeout: Double = 1.5
}

/// Window scaling presets matching iPhone Mirroring's View menu.
enum WindowScalePreset: String, CaseIterable {
    case smaller = "Smaller"
    case actualSize = "Actual Size"
    case larger = "Larger"

    var multiplier: CGFloat {
        switch self {
        case .smaller: return 0.75
        case .actualSize: return 1.0
        case .larger: return 1.25
        }
    }

    var keyboardShortcut: KeyEquivalent? {
        switch self {
        case .larger: return "+"
        case .smaller: return "-"
        case .actualSize: return "0"
        }
    }
}
