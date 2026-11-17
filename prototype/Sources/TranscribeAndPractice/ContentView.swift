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
                Button("Zoom Out Full", systemImage: "arrow.left.and.right.square") { state.zoomOutFull() }
                    .disabled(!state.canZoomOutFull)
                    .help("Zoom out to show the whole file")
            }
            ToolbarItem {
                Button("Zoom to Selection", systemImage: "arrow.right.and.line.vertical.and.arrow.left") {
                    state.zoomToSelection()
                }
                .disabled(!state.canZoomToSelection)
                .help("Zoom to the selection")
            }
            ToolbarItem {
                Text(state.selectionText)
                    .monospacedDigit()
                    .foregroundStyle(state.selection == nil ? .secondary : .primary)
                    .frame(minWidth: 220)
                    .padding(.horizontal, 8)
                    .help("Selection: start – end (length)")
                    .accessibilityLabel("Selection")
                    .accessibilityValue(state.selectionText)
            }
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
                navigator(horizontal: horizontal)
                    .frame(width: horizontal ? nil : nav, height: horizontal ? nav : nil)
                    .reportFrame("navigator")
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
        WaveformView(name: name, state: state, background: background)
            .reportFrame(name)
    }

    /// Navigator waveform with the scrollbar along its time axis (bottom / right edge).
    private func navigator(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        let t = TimeScrollerView.thickness
        return layout {
            WaveformView(name: "navigator", state: state, background: .underPageBackgroundColor)
                .reportFrame("navigatorWaveform")
            TimeScrollerView(state: state, vertical: !horizontal)
                .id(horizontal)
                .frame(width: horizontal ? nil : t, height: horizontal ? t : nil)
                .reportFrame("scrollbar")
        }
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
