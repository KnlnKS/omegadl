import SwiftUI

extension EnvironmentValues {
    var fluidAnimation: Animation {
        accessibilityReduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)
    }

    var settleAnimation: Animation {
        accessibilityReduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.25, bounce: 0)
    }
}
