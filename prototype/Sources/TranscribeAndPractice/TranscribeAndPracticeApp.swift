import SwiftUI

@main
struct TranscribeAndPracticeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    var body: some Scene {
        Window(appName, id: "main") {
            ContentView().environment(state)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { state.showOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let options = VerificationHooks.Options(arguments: CommandLine.arguments) {
            VerificationHooks.run(options, state: AppState.shared)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
