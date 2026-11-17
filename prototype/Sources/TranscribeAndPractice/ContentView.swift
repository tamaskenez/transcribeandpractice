import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            MiddleSection()
            Divider()
            TransportPane()
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .navigationTitle(state.windowTitle)
        .toolbar {
            ToolbarItem {
                Picker("Time Orientation", selection: $state.orientation) {
                    Label("Horizontal Time", systemImage: "arrow.right").tag(TimeOrientation.horizontal)
                    Label("Vertical Time", systemImage: "arrow.down").tag(TimeOrientation.vertical)
                }
                .pickerStyle(.segmented)
                .help("Time orientation")
            }
        }
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

/// Navigator and main pane with a draggable divider; stacked (horizontal time) or side by side
/// (vertical time).
private struct MiddleSection: View {
    @Environment(AppState.self) private var state
    private let dividerThickness: CGFloat = 1
    private let hitThickness: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let horizontal = state.orientation == .horizontal
            let total = horizontal ? geo.size.height : geo.size.width
            let nav = (max(total - dividerThickness, 0) * state.navigatorFraction).rounded()
            let layout = horizontal ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                pane("navigator", background: .underPageBackgroundColor)
                    .frame(width: horizontal ? nil : nav, height: horizontal ? nav : nil)
                divider(horizontal: horizontal, total: total)
                pane("main", background: .textBackgroundColor)
                    .overlay {
                        if state.audio == nil {
                            Text("Open an audio file (⌘O)").font(.title3).foregroundStyle(.secondary)
                        }
                    }
            }
            .coordinateSpace(.named("middle"))
        }
    }

    private func pane(_ name: String, background: NSColor) -> some View {
        WaveformView(name: name, mono: state.audio?.mono ?? [], orientation: state.orientation, background: background)
            .reportFrame(name)
    }

    private func divider(horizontal: Bool, total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? nil : dividerThickness, height: horizontal ? dividerThickness : nil)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? nil : hitThickness, height: horizontal ? hitThickness : nil)
                    .contentShape(Rectangle())
                    .pointerStyle(horizontal ? .rowResize : .columnResize)
                    .gesture(DragGesture(coordinateSpace: .named("middle")).onChanged { drag in
                        let pos = horizontal ? drag.location.y : drag.location.x
                        state.navigatorFraction = min(max(pos / max(total, 1), 0.05), 0.95)
                    })
            }
            .zIndex(1)
            .reportFrame("divider")
    }
}

private struct TransportPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            Text(state.transportSummary ?? " ")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .reportFrame("transport")
    }
}

extension View {
    /// Records the view's frame (window content coordinates) in AppState for the state dump.
    func reportFrame(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            AppState.shared.paneFrames[name] = frame
        }
    }
}
