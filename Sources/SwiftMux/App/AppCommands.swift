import Foundation
import SwiftUI

extension Notification.Name {
    static let swiftMuxOpenCommandPalette = Notification.Name("swiftmux.open-command-palette")
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Command Palette") {
                NotificationCenter.default.post(name: .swiftMuxOpenCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
    }
}
