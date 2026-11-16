import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            if let audio = state.audio {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(infoRows(for: audio).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(row.value).monospacedDigit().textSelection(.enabled)
                        }
                    }
                }
                .padding(24)
            } else {
                Text("Open an audio file (⌘O)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .navigationTitle(state.windowTitle)
        .alert("Could not open file",
               isPresented: Binding(get: { state.errorMessage != nil },
                                    set: { if !$0 { state.errorMessage = nil } }),
               presenting: state.errorMessage) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}
