import SwiftUI
import SwiftMuxCore

extension SessionStatus {
    var color: Color {
        switch self {
        case .active:
            return AppTheme.activeAccent
        case .idle:
            return AppTheme.idleAccent
        case .done:
            return AppTheme.doneAccent
        case .waitingHuman:
            return AppTheme.waitingAccent
        case .unknown:
            return AppTheme.unknownAccent
        }
    }
}
