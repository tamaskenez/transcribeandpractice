import AppKit
import SwiftUI

/// Development aid for headless verification. Launch arguments:
///   --open=<file>         open a file (repeatable, in order; same code path as File → Open)
///   --dump-state=<file>   write the app state as JSON
///   --snapshot=<file>     save a PNG of the window content
///   --quit                quit when done
/// Values must use the `=` form: a bare path argument can make AppKit treat the launch as
/// "open this file", and then SwiftUI doesn't create the main window.
@MainActor
enum VerificationHooks {
    struct Options {
        var open: [String] = []
        var dumpState: String?
        var snapshot: String?
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

    /// Renders the window's SwiftUI content with ImageRenderer at the window's content size.
    /// (Capturing the real window needs Screen Recording permission; cacheDisplay and
    /// CALayer.render come out blank for SwiftUI content.)
    @MainActor
    private static func snapshot(to path: String, state: AppState) {
        let size = mainWindow?.contentView?.bounds.size ?? CGSize(width: 480, height: 300)
        let content = ContentView()
            .environment(state)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = mainWindow?.backingScaleFactor ?? 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot failed: render\n".utf8))
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        }
    }
}
