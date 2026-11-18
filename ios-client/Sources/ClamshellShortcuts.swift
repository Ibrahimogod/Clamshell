import AppIntents

/// The phrases Siri and Spotlight know without setup (1.1).
struct ClamshellShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectToMacIntent(), phrases: ["Connect to my Mac with \(.applicationName)", "\(.applicationName) connect"],
                    shortTitle: "Connect to Mac", systemImageName: "laptopcomputer.and.iphone")
        AppShortcut(intent: DisconnectFromMacIntent(), phrases: ["Disconnect \(.applicationName)"],
                    shortTitle: "Disconnect", systemImageName: "xmark.circle")
    }
}
