import SwiftUI

@main
struct TranscribeAndPracticeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    var body: some Scene {
        Window(appName, id: "main") {
            ContentView().environment(state)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { state.showOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                orientationItem("Horizontal Time", .horizontal, key: "1")
                orientationItem("Vertical Time", .vertical, key: "2")
                Divider()
            }
        }
    }

    private func orientationItem(_ title: String, _ value: TimeOrientation, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(get: { state.orientation == value },
                                    set: { if $0 { state.orientation = value } }))
            .keyboardShortcut(key, modifiers: .command)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Escape clears the selection (unless an alert or sheet is shown).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let state = AppState.shared
            if event.keyCode == 53, event.window?.attachedSheet == nil, event.window?.isSheet == false,
               state.errorMessage == nil, state.selection != nil {
                state.selection = nil
                return nil
            }
            return event
        }
        if let options = VerificationHooks.Options(arguments: CommandLine.arguments) {
            VerificationHooks.run(options, state: AppState.shared)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
