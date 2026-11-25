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
                Toggle("Show Beats", isOn: Binding(get: { state.stripShowsBeats }, set: { state.showBeats = $0 }))
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(!state.beatsAvailable)
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
        // Escape, Space, Left, Right, Down Arrow, B, Shift+B, Backspace (unless an alert or sheet is shown).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let state = AppState.shared
            guard event.window?.attachedSheet == nil, event.window?.isSheet == false, state.errorMessage == nil,
                  state.beatDialog == nil,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            else { return event }
            // B / Shift+B: place a beat (Shift: a downbeat).
            if event.keyCode == 11 { state.beatKey(downbeat: event.modifierFlags.contains(.shift)); return nil }
            guard !event.modifierFlags.contains(.shift) else { return event }
            switch event.keyCode {
            case 51 where !state.isPlaying && (state.hoveredBeatSample != nil || !state.selectedBeats.isEmpty):
                state.deleteHoveredBeat()                                        // Backspace
            case 53 where !state.selectedBeats.isEmpty: state.clearBeatSelection() // Escape: beats first
            case 53 where state.selection != nil: state.clearSelectionWithKey()  // Escape
            case 49: state.playOrStop()                                          // Space
            case 123: state.rewindAndPlay()                                      // Left Arrow
            case 124: state.playAgain()                                          // Right Arrow
            case 125: state.setLastStartToPlayhead()                             // Down Arrow
            default: return event
            }
            return nil
        }
        if let options = VerificationHooks.Options(arguments: CommandLine.arguments) {
            VerificationHooks.run(options, state: AppState.shared)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
