import AppKit
import SwiftUI

/// Development aid for headless verification. Launch arguments:
///   --open=<file>         open a file (repeatable, in order; same code path as File → Open)
///   --dump-state=<file>   write the app state as JSON
///   --orientation=horizontal|vertical  set the time orientation (same path as the toggle)
///   --snapshot=<file>     save a PNG of the real window (screencapture; needs Screen Recording)
///   --quit                quit when done
/// Values must use the `=` form: a bare path argument can make AppKit treat the launch as
/// "open this file", and then SwiftUI doesn't create the main window.
@MainActor
enum VerificationHooks {
    struct Options {
        var open: [String] = []
        var dumpState: String?
        var snapshot: String?
        var orientation: TimeOrientation?
        var quit = false

        init?(arguments: [String]) {
            var any = false
            for arg in arguments.dropFirst() {
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                let value = parts.count == 2 ? parts[1] : nil
                switch parts[0] {
                case "--open": if let value { open.append(value); any = true }
                case "--dump-state": dumpState = value; any = true
                case "--snapshot": snapshot = value; any = true
                case "--orientation": orientation = value.flatMap(TimeOrientation.init(rawValue:)); any = true
                case "--quit": quit = true; any = true
                default: break
                }
            }
            if !any { return nil }
        }
    }

    @MainActor
    static func run(_ options: Options, state: AppState) {
        Task { @MainActor in
            // Wait (up to 10 s) for the window to appear.
            for _ in 0..<100 where mainWindow == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let o = options.orientation { state.orientation = o }
            for path in options.open {
                state.open(url: URL(fileURLWithPath: path))
            }
            try? await Task.sleep(for: .milliseconds(500)) // let SwiftUI update the window
            if let path = options.dumpState { dumpState(to: path, state: state) }
            if let path = options.snapshot { snapshot(to: path, state: state) }
            if options.quit { NSApp.terminate(nil) }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.className != "NSStatusBarWindow" }
    }

    @MainActor
    private static func dumpState(to path: String, state: AppState) {
        var dict: [String: Any] = [
            "windowTitle": mainWindow?.title ?? NSNull(),
            "windowCount": NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }.count,
            "alertText": state.errorMessage ?? NSNull(),
            "allWindows": NSApp.windows.map { "\($0.className) visible=\($0.isVisible) title=\($0.title)" },
            "hintVisible": state.audio == nil,
            "menu": menuDump(NSApp.mainMenu),
            "orientation": state.orientation.rawValue,
            "navigatorFraction": state.navigatorFraction,
            "windowNumber": mainWindow?.windowNumber ?? NSNull(),
            "contentSize": mainWindow?.contentView.map { size($0.bounds.size) } ?? NSNull(),
            "paneFrames": state.paneFrames.mapValues(rect),
            "transportText": state.transportSummary ?? NSNull(),
            "toolbar": toolbarDump(state: state),
            "waveforms": waveformDump(),
        ]
        if let audio = state.audio {
            let format = audio.buffer.format
            let stats: [[String: Any]] = audio.channelStats.map {
                ["peakDBFS": $0.peakDBFS ?? NSNull(), "rmsDBFS": $0.rmsDBFS ?? NSNull()]
            }
            let bufferFormat: [String: Any] = [
                "commonFormat": format.commonFormat == .pcmFormatFloat32 ? "float32" : "other",
                "interleaved": format.isInterleaved,
                "channels": Int(format.channelCount),
                "sampleRate": format.sampleRate,
                "frames": Int(audio.buffer.frameLength),
            ]
            let rows: [[String: String]] = infoRows(for: audio).map { ["label": $0.label, "value": $0.value] }
            let loaded: [String: Any] = [
                "path": audio.url.path,
                "fileName": audio.fileName,
                "duration": audio.duration,
                "sampleRate": audio.sampleRate,
                "channels": audio.channelCount,
                "frames": audio.frameCount,
                "channelStats": stats,
                "bufferFormat": bufferFormat,
                "displayedRows": rows,
            ]
            dict["loaded"] = loaded
        } else {
            dict["loaded"] = NSNull()
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("dump-state failed: \(error)\n".utf8))
        }
    }

    private static func rect(_ r: CGRect) -> [String: Double] {
        ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
    }

    private static func size(_ s: CGSize) -> [String: Double] { ["width": s.width, "height": s.height] }

    private static func toolbarDump(state: AppState) -> [String: Any] {
        let items = mainWindow?.toolbar?.items.map { item -> [String: Any] in
            ["identifier": item.itemIdentifier.rawValue, "label": item.label]
        } ?? []
        return ["visible": mainWindow?.toolbar?.isVisible ?? false, "items": items,
                "orientationSelection": state.orientation.rawValue]
    }

    /// The waveform views actually in the window, with the polyline each one draws.
    private static func waveformDump() -> [String: Any] {
        var result: [String: Any] = [:]
        func visit(_ view: NSView) {
            if let w = view as? WaveformNSView {
                let points = waveformPoints(mono: w.mono, size: w.bounds.size, orientation: w.orientation)
                result[w.name] = [
                    "size": size(w.bounds.size),
                    "orientation": w.orientation.rawValue,
                    "frames": w.mono.count,
                    "points": points.map { [$0.x, $0.y] },
                ] as [String: Any]
            }
            view.subviews.forEach(visit)
        }
        if let root = mainWindow?.contentView?.superview ?? mainWindow?.contentView { visit(root) }
        return result
    }

    private static func menuDump(_ menu: NSMenu?) -> [[String: Any]] {
        guard let menu else { return [] }
        return menu.items.filter { !$0.isSeparatorItem }.map { item in
            var d: [String: Any] = ["title": item.title]
            if !item.keyEquivalent.isEmpty {
                var mods: [String] = []
                let m = item.keyEquivalentModifierMask
                if m.contains(.control) { mods.append("ctrl") }
                if m.contains(.option) { mods.append("option") }
                if m.contains(.shift) { mods.append("shift") }
                if m.contains(.command) { mods.append("cmd") }
                d["shortcut"] = (mods + [item.keyEquivalent]).joined(separator: "+")
            }
            if let sub = item.submenu { d["items"] = menuDump(sub) }
            return d
        }
    }

    /// Captures the real window, including the toolbar, with screencapture. Needs Screen Recording
    /// permission for the responsible process (the terminal when launched from it).
    private static func snapshot(to path: String, state: AppState) {
        guard let number = mainWindow?.windowNumber else {
            FileHandle.standardError.write(Data("snapshot failed: no window\n".utf8))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(number), path]
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                FileHandle.standardError.write(Data("snapshot failed: screencapture exit \(p.terminationStatus)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        }
    }
}
