import AppKit
import SwiftUI

/// Development aid for headless verification. Launch arguments:
///   --open=<file>         open a file (repeatable, in order; same code path as File → Open)
///   --dump-state=<file>   write the app state as JSON
///   --orientation=horizontal|vertical  set the time orientation (same path as the toggle)
///   --snapshot=<file>     save a PNG of the real window (screencapture; needs Screen Recording)
///   --view=<start>,<end>  set the visible range in seconds (same path as the gestures)
///   --select=<start>,<end>  set the selection in seconds
///   --commands=<file>     keep running and execute lines appended to <file>:
///                         dump <path> | snapshot <path> | quit | view <s>,<e> | select <s>,<e>
///                         | orientation <o> | open <path> | resize <w>,<h> | activate
///                         | amplitude <dB> | playhead <s> | loop on|off | follow on|off
///                         | record <path> | record stop
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
        var view: (Double, Double)?
        var select: (Double, Double)?
        var commands: String?
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
                case "--view": view = value.flatMap(pair); any = true
                case "--select": select = value.flatMap(pair); any = true
                case "--commands": commands = value; any = true
                case "--quit": quit = true; any = true
                default: break
                }
            }
            if !any { return nil }
        }
    }

    nonisolated static func pair(_ s: String) -> (Double, Double)? {
        let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return v.count == 2 ? (v[0], v[1]) : nil
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
            if let (a, b) = options.view { state.setView(start: a, end: b) }
            if let (a, b) = options.select { state.select(a, b) }
            try? await Task.sleep(for: .milliseconds(500)) // let SwiftUI update the window
            if let path = options.dumpState { dumpState(to: path, state: state) }
            if let path = options.snapshot { snapshot(to: path, state: state) }
            if let path = options.commands { await serveCommands(path, state: state) }
            if options.quit { NSApp.terminate(nil) }
        }
    }

    /// Polls `path` for appended lines and executes them, until `quit`. Each command is
    /// acknowledged by appending "ok <n>" to `<path>.ack` (n = commands done so far).
    private static var recordPath: String?

    private static func serveCommands(_ path: String, state: AppState) async {
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        var done = 0
        while true {
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            if lines.count > done {
                for line in lines[done...] {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    let arg = parts.count > 1 ? parts[1] : ""
                    switch parts.first ?? "" {
                    case "quit": return
                    case "dump": dumpState(to: arg, state: state)
                    case "snapshot": snapshot(to: arg, state: state)
                    case "view": if let (a, b) = pair(arg) { state.setView(start: a, end: b) }
                    case "select": if let (a, b) = pair(arg) { state.select(a, b) } else { state.selection = nil }
                    case "orientation": if let o = TimeOrientation(rawValue: arg) { state.orientation = o }
                    case "open": state.open(url: URL(fileURLWithPath: arg))
                    case "resize":
                        if let (w, h) = pair(arg), let win = mainWindow { win.setContentSize(NSSize(width: w, height: h)) }
                    case "activate": NSApp.activate(); mainWindow?.makeKeyAndOrderFront(nil)
                    case "amplitude": if let v = Double(arg) { state.setAmplitudeZoom(dB: v) }
                    case "playhead": if let v = Double(arg) { state.clickedToClear(at: v) }
                    case "loop": state.loopEnabled = arg == "on"
                    case "follow": state.followPlayhead = arg == "on"
                    case "record":
                        if arg == "stop" {
                            let data = state.player.core.stopRecording()
                            if let path = recordPath {
                                try? writeFloatWAV(path: path, channels: data, sampleRate: state.audio?.sampleRate ?? 44100)
                            }
                            recordPath = nil
                        } else {
                            recordPath = arg
                            state.player.core.startRecording()
                        }
                    default: break
                    }
                    done += 1
                    // Let SwiftUI and AppKit update before the next command (layout, redraw).
                    try? await Task.sleep(for: .milliseconds(150))
                    let ack = "ok \(done)\n"
                    if let h = FileHandle(forWritingAtPath: path + ".ack") {
                        h.seekToEndOfFile(); h.write(Data(ack.utf8)); try? h.close()
                    } else {
                        FileManager.default.createFile(atPath: path + ".ack", contents: Data(ack.utf8))
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(30))
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
            "appActive": NSApp.isActive,
            "windowKey": mainWindow?.isKeyWindow ?? false,
            "contentSize": mainWindow?.contentView.map { size($0.bounds.size) } ?? NSNull(),
            "paneFrames": state.paneFrames.mapValues(rect),
            "transportText": state.transportSummary ?? NSNull(),
            "toolbar": toolbarDump(state: state),
            "waveforms": waveformDump(),
            "view": ["start": state.viewStart, "end": state.viewEnd],
            "selection": state.selection.map { ["start": $0.lowerBound, "end": $0.upperBound] } ?? NSNull(),
            "selectionText": state.selectionText,
            "amplitudeZoomDB": state.amplitudeZoomDB,
            "currentCursor": cursorName(NSCursor.current),
            "playback": playbackDump(state: state),
            "buttons": ["zoomOutFull": state.canZoomOutFull, "zoomToSelection": state.canZoomToSelection],
            "scrollbar": scrollerDump(),
            "screenFrames": screenFrames(state: state),
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
                let points = w.points()
                result[w.name] = [
                    "size": size(w.bounds.size),
                    "orientation": w.orientation.rawValue,
                    "frames": w.state?.audio?.mono.count ?? 0,
                    "cursor": w.cursorName,
                    "playheadAxis": w.playheadAxis.map { Double($0) } ?? NSNull(),
                    "points": points.map { [$0.x, $0.y] },
                ] as [String: Any]
            }
            view.subviews.forEach(visit)
        }
        if let root = mainWindow?.contentView?.superview ?? mainWindow?.contentView { visit(root) }
        return result
    }

    private static func allViews() -> [NSView] {
        var out: [NSView] = []
        func visit(_ v: NSView) { out.append(v); v.subviews.forEach(visit) }
        if let root = mainWindow?.contentView?.superview ?? mainWindow?.contentView { visit(root) }
        return out
    }

    private static func playbackDump(state: AppState) -> [String: Any] {
        let p = state.player, c = p.core
        let (callbacks, updates, lastFrames, raw) = c.withLock { (c.callbackCount, c.playheadUpdates, c.lastCallbackFrames, c.playheadFrame) }
        let (rendered, bufferStart, startFrame, latencyFrames) = c.withLock { (c.rendered, c.lastBufferStart, c.startFrame, c.latencyFrames) }
        return [
            "playing": state.isPlaying, "playhead": state.playhead, "rewindPoint": state.rewindPoint,
            "lastStart": state.lastStart, "loop": state.loopEnabled, "follow": state.followPlayhead,
            "ioBufferFrames": p.ioBufferFrames, "deviceSampleRate": p.deviceSampleRate,
            "latencySeconds": p.latencySeconds, "refreshRate": p.refreshRate,
            "targetBufferSeconds": p.targetBufferSeconds, "callbackCount": callbacks,
            "playheadUpdates": updates, "lastCallbackFrames": lastFrames, "corePlayheadFrame": raw,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "renderedFrames": rendered, "lastBufferStart": bufferStart, "startFrame": startFrame,
            "latencyFrames": latencyFrames,
        ]
    }

    private static func cursorName(_ c: NSCursor) -> String {
        let known: [(NSCursor, String)] = [(.arrow, "arrow"), (.openHand, "openHand"), (.closedHand, "closedHand"),
                                           (.columnResize, "columnResize"), (.rowResize, "rowResize")]
        return known.first { $0.0 == c }?.1 ?? "other"
    }

    private static func scrollerDump() -> Any {
        guard let s = allViews().compactMap({ $0 as? TimeScroller }).first else { return NSNull() }
        return ["vertical": s.bounds.height > s.bounds.width, "enabled": s.isEnabled,
                "knobProportion": s.knobProportion, "value": s.doubleValue,
                "style": s.scrollerStyle == .legacy ? "legacy" : "overlay",
                "knobRect": rect(s.rect(for: .knob)), "size": size(s.bounds.size),
                "knobSlot": rect(s.rect(for: .knobSlot)),
                "playheadMark": s.playheadMark.map { Double($0) } ?? NSNull()] as [String: Any]
    }

    /// Frames of the panes and the scrollbar in global screen coordinates with a top-left origin
    /// (Quartz event coordinates), for posting synthetic events.
    private static func screenFrames(state: AppState) -> [String: Any] {
        guard let win = mainWindow, let primary = NSScreen.screens.first else { return [:] }
        func cg(_ v: NSView) -> [String: Double] {
            let r = win.convertToScreen(v.convert(v.bounds, to: nil))
            return rect(CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height))
        }
        var out: [String: Any] = [:]
        for v in allViews() {
            if let w = v as? WaveformNSView { out[w.name] = cg(w) }
            if v is TimeScroller { out["scrollbar"] = cg(v) }
        }
        if let c = win.contentView { out["content"] = cg(c) }
        return out
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
