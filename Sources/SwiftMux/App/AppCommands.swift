import Foundation
import SwiftUI

extension Notification.Name {
    static let swiftMuxOpenCommandPalette = Notification.Name("swiftmux.open-command-palette")
    static let swiftMuxSelectSidebarSessionIndex = Notification.Name("swiftmux.select-sidebar-session-index")
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Command Palette") {
                NotificationCenter.default.post(name: .swiftMuxOpenCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("Select Session \(index)") {
                    NotificationCenter.default.post(
                        name: .swiftMuxSelectSidebarSessionIndex,
                        object: nil,
                        userInfo: ["index": index - 1]
                    )
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: [.command])
            }
        }
    }
}
