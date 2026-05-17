import Foundation
import SwiftUI

extension Notification.Name {
    static let swiftMuxOpenNewSession = Notification.Name("swiftmux.open-new-session")
    static let swiftMuxOpenCommandPalette = Notification.Name("swiftmux.open-command-palette")
    static let swiftMuxSelectSidebarSessionIndex = Notification.Name("swiftmux.select-sidebar-session-index")
    static let swiftMuxShowHelp = Notification.Name("swiftmux.show-help")
    static let swiftMuxFocusSidebarSearch = Notification.Name("swiftmux.focus-sidebar-search")
    static let swiftMuxRefreshSessions = Notification.Name("swiftmux.refresh-sessions")
    static let swiftMuxRefreshPullRequests = Notification.Name("swiftmux.refresh-pull-requests")
    static let swiftMuxRunReap = Notification.Name("swiftmux.run-reap")
    static let swiftMuxShowRemoteControl = Notification.Name("swiftmux.show-remote-control")
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") {
                NotificationCenter.default.post(name: .swiftMuxOpenNewSession, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])
        }

        CommandMenu("Navigate") {
            Button("Search Sessions") {
                NotificationCenter.default.post(name: .swiftMuxFocusSidebarSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Command Palette") {
                NotificationCenter.default.post(name: .swiftMuxOpenCommandPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Refresh Sessions") {
                NotificationCenter.default.post(name: .swiftMuxRefreshSessions, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command])

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

        CommandMenu("Tools") {
            Button("Remote Control…") {
                NotificationCenter.default.post(name: .swiftMuxShowRemoteControl, object: nil)
            }

            Divider()

            Button("Refresh PR Metadata") {
                NotificationCenter.default.post(name: .swiftMuxRefreshPullRequests, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("tp reap") {
                postReap(dryRun: false)
            }

            Button("tp reap --dry-run") {
                postReap(dryRun: true)
            }
        }

        CommandGroup(after: .help) {
            Button("SwiftMux Help") {
                postHelp(topic: .overview)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])

            Button("Keyboard Shortcuts") {
                postHelp(topic: .shortcuts)
            }

            Button("Session Actions") {
                postHelp(topic: .sessions)
            }
        }
    }

    private func postHelp(topic: SwiftMuxHelpTopic) {
        NotificationCenter.default.post(
            name: .swiftMuxShowHelp,
            object: nil,
            userInfo: ["topic": topic.rawValue]
        )
    }

    private func postReap(dryRun: Bool) {
        NotificationCenter.default.post(
            name: .swiftMuxRunReap,
            object: nil,
            userInfo: ["dryRun": dryRun]
        )
    }
}
