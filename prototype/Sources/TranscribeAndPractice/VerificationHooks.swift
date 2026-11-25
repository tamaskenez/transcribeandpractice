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
///                         | record <path> | record stop | beats on|off
///                         | beatkey [shift] | tsdialog ok|dontset|numerator <text>|denominator <d>
///                         | mode waveform|spectrogram | window <ms> | specdump <path> | specdelay <ms>
///                         | scrollpan <dx>,<dy> (a plain scroll's pan in the main pane, fractional points)
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
                    case "beats": state.showBeats = arg == "on"
                    case "beatkey": state.beatKey(downbeat: arg == "shift")
                    case "gridlines": state.gridLinesShown = arg == "on"
                    case "grid":
                        let a = arg.split(separator: " ").map(String.init)
                        if let k = a.first.flatMap(GridKind.init(rawValue:)) {
                            state.gridKind = k
                            if a.count > 1, let n = Int(a[1]) {
                                switch k {
                                case .straight: if GridConstants.straight.contains(n) { state.gridStraight = n }
                                case .triplet: if GridConstants.triplet.contains(n) { state.gridTriplet = n }
                                case .tuplet: if GridConstants.tupletRange.contains(n) { state.gridTuplet = n }
                                }
                            }
                        }
                    case "mode": if let m = MainPaneMode(rawValue: arg) { state.mainMode = m }
                    case "window": if let v = Double(arg) { state.windowLengthMs = v }
                    case "specdelay": SpectrogramConstants.testDelayMs = Int(arg) ?? 0
                    case "scrollpan":
                        if let (dx, dy) = pair(arg),
                           let v = allViews().compactMap({ $0 as? WaveformNSView }).first(where: { $0.name == "main" }) {
                            v.scrollPan(dx: dx, dy: dy)
                        }
                    case "specdump":
                        let d = state.spectrogram.levelsDump(state: state)
                        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) {
                            try? data.write(to: URL(fileURLWithPath: arg))
                        }
                    case "tsdialog":
                        let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
                        switch a.first ?? "" {
                        case "ok": state.answerTimeSignatureDialog(ok: true)
                        case "cancel": state.answerTimeSignatureDialog(ok: false)
                        case "mode": state.tsChange = a.count > 1 && a[1] == "change"
                        case "numerator": state.tsNumerator = a.count > 1 ? a[1] : ""
                        case "denominator": if a.count > 1, let d = Int(a[1]) { state.tsDenominator = d }
                        default: break
                        }
                    case "subdivide":
                        switch arg {
                        case "ok": state.answerSubdivideDialog(ok: true)
                        case "cancel": state.answerSubdivideDialog(ok: false)
                        default: state.subdivideText = arg
                        }
                    case "beatsel":
                        // Beat indices, comma-separated ("none" clears); the last one is the anchor.
                        state.clearBeatSelection()
                        for i in arg.split(separator: ",").compactMap({ Int($0) }) where state.beats.indices.contains(i) {
                            state.toggleBeat(id: state.beats[i].id)
                        }
                    case "beatmenu":
                        // Runs the beat context menu item with this title.
                        if let item = allViews().compactMap({ $0 as? WaveformNSView }).first(where: { $0.isRuler })?
                            .beatMenu()?.items.first(where: { $0.title == arg }), item.isEnabled, let action = item.action {
                            NSApp.sendAction(action, to: item.target, from: item)
                        }
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
            "alertTitle": state.errorMessage == nil ? NSNull() : state.errorTitle as Any,
            "beats": zip(state.beats, state.beatPositions).map { b, p -> [String: Any] in
                ["sample": b.sample, "timeSignature": b.timeSignature ?? NSNull(), "firstBeat": b.bar.rawValue,
                 "barNumber": p.bar, "beatInBar": p.beatInBar, "signature": p.signature.description,
                 "effective": p.effective?.description ?? NSNull(), "selected": state.selectedBeats.contains(b.id)]
            },
            "selectedBeats": state.selectedBeatIndices,
            "beatAnchor": state.beatAnchor.flatMap { a in state.beats.firstIndex { $0.id == a } } ?? NSNull(),
            "beatMenu": (allViews().compactMap { $0 as? WaveformNSView }.first { $0.isRuler }?.beatMenu()?.items ?? [])
                .map { ["title": $0.title, "enabled": $0.isEnabled, "checked": $0.state == .on,
                        "separator": $0.isSeparatorItem, "header": $0.isSectionHeader] },
            "selectedBeatAxes": (allViews().compactMap { $0 as? WaveformNSView }.first { $0.isRuler }?.selectedBeatAxes() ?? [])
                .map { Double($0) },
            "beepCount": state.beepCount,
            "hoveredBeat": state.hoveredBeatSample ?? NSNull(),
            "beatDialog": state.beatDialog.map { d -> String in if case .subdivide = d { "subdivide" } else { "timeSignature" } } ?? NSNull(),
            "timeSignatureDialog": ["change": state.tsChange, "inherited": state.tsInherited.description,
                                    "numerator": state.tsNumerator, "denominator": state.tsDenominator,
                                    "okEnabled": state.tsDialogValid, "denominatorOptions": timeSignatureDenominators,
                                    "sheetVisible": mainWindow?.attachedSheet?.isVisible ?? false] as [String: Any],
            "subdivideDialog": ["text": state.subdivideText, "max": state.maxSubdivision,
                                "okEnabled": state.subdivideValue != nil] as [String: Any],
            "beatConstants": ["beatNote": BeatConstants.beatNote.description, "maxReasonableBPM": BeatConstants.maxReasonableBPM],
            "showBeats": ["stored": state.showBeats, "enabled": state.beatsAvailable, "on": state.stripShowsBeats],
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
            "ruler": rulerDump(),
            "view": ["start": state.viewStart, "end": state.viewEnd],
            "selection": state.selection.map { ["start": $0.lowerBound, "end": $0.upperBound] } ?? NSNull(),
            "selectionText": state.selectionText,
            "amplitudeZoomDB": state.amplitudeZoomDB,
            "currentCursor": cursorName(NSCursor.current),
            "playback": playbackDump(state: state),
            "buttons": ["zoomOutFull": state.canZoomOutFull, "zoomToSelection": state.canZoomToSelection],
            "scrollbar": scrollerDump(),
            "screenFrames": screenFrames(state: state),
            "spectrogram": spectrogramDump(state: state),
            "spectrum": spectrumDump(),
            "grid": ["linesShown": state.gridLinesShown, "kind": state.gridKind.rawValue, "straight": state.gridStraight,
                     "triplet": state.gridTriplet, "tuplet": state.gridTuplet, "n": state.gridDenominator],
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

    private static func spectrogramDump(state: AppState) -> [String: Any] {
        let e = state.spectrogram
        let fs = state.audio?.sampleRate ?? 44100
        let rps = state.rowsPerSemitone
        let low = state.freqBottom
        let rows = Double(state.mainCrossLength).rounded()
        return [
            "mode": state.mainMode.rawValue, "windowLengthMs": state.windowLengthMs,
            "windowSamples": SpectrogramConstants.windowLength(seconds: state.windowLengthMs / 1000, sampleRate: fs),
                        "timePixels": state.timePixels, "pixelSeconds": state.pixelSeconds ?? NSNull(),
            "panRemainder": state.panRemainder, "lastScrollDelta": state.lastScrollDelta,
            "freqView": ["low": low, "high": low + rows / rps, "pointsPerSemitone": SpectrogramConstants.pointsPerSemitone,
                         "rowsPerSemitone": rps, "stored": state.freqLow ?? NSNull()] as [String: Any],
            "busy": state.spectrogramBusy, "complete": e.complete,
            "computedColumns": e.computedColumns, "cachedColumns": e.cachedColumns,
            "staleShown": !e.complete && e.stale != nil, "origin": e.origin, "staleDraws": e.staleDraws,
            "renderedGainDB": e.renderedGainDB ?? NSNull(),
        ]
    }

    /// The spectrum pane (milestone 9): its column and key outline lines as drawn.
    private static func spectrumDump() -> [String: Any] {
        guard let v = allViews().compactMap({ $0 as? SpectrumNSView }).first else { return ["shown": false] }
        var d: [String: Any] = ["shown": true, "size": size(v.bounds.size), "orientation": v.orientation.rawValue]
        if let c = v.columnDump() {
            d["centreSample"] = c.centre
            d["firstRow"] = c.firstRow
            d["levels"] = c.levels.map { $0.map { Double($0) as Any } ?? NSNull() }
        }
        d["keyLines"] = v.keyLines().map {
            ["kind": $0.kind, "freq": [$0.freq.lowerBound, $0.freq.upperBound],
             "depth": [$0.depth.lowerBound, $0.depth.upperBound], "rect": rect($0.rect)] as [String: Any]
        }
        return d
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
            if let w = view as? WaveformNSView, !w.isRuler {
                let bars = w.columnBars()
                result[w.name] = [
                    "size": size(w.bounds.size),
                    "orientation": w.orientation.rawValue,
                    "frames": w.state?.audio?.mono.count ?? 0,
                    "cursor": w.cursorName,
                    "playheadAxis": w.playheadAxis.map { Double($0) } ?? NSNull(),
                    "lastStartAxis": w.lastStartAxis.map { Double($0) } ?? NSNull(),
                    "columns": bars.map { b -> [String: Any] in
                        ["j": b.column.index, "min": b.column.min, "max": b.column.max, "rms": b.column.rms,
                         "axis": [b.axis.lowerBound, b.axis.upperBound],
                         "bar": b.bar.map { [$0.lowerBound, $0.upperBound] } ?? NSNull(),
                         "rmsBar": b.rmsBar.map { [$0.lowerBound, $0.upperBound] } ?? NSNull()]
                    },
                    "columnComputations": w.columnComputations,
                    "lastColumnsMs": w.lastColumnsMs ?? NSNull(),
                    "analysisWindow": w.analysisWindowPolylines().map { $0.map { $0.map { [$0.x, $0.y] } } } ?? NSNull(),
                    "editorLines": w.visibleEditorLines().map { ["kind": $0.line.kind.rawValue, "time": $0.line.time, "axis": $0.axis] },
                    "zoomAxis": w.zoomTimeAxis.map { $0 ? "time" : "amplitude" } ?? NSNull(),
                ] as [String: Any]
            }
            view.subviews.forEach(visit)
        }
        if let root = mainWindow?.contentView?.superview ?? mainWindow?.contentView { visit(root) }
        return result
    }

    /// The navigator's time-marker strip and its ticks as drawn.
    private static func rulerDump() -> Any {
        guard let r = allViews().compactMap({ $0 as? WaveformNSView }).first(where: \.isRuler) else { return NSNull() }
        let ticks: [[String: Any]] = r.rulerTicks().map {
            ["time": $0.time, "axis": $0.axis, "major": $0.major, "label": $0.label.map { $0 as Any } ?? NSNull(),
             "labelFrame": $0.labelFrame.map(rect) ?? NSNull()]
        }
        let marks: [[String: Any]] = r.beatMarks().map {
            ["time": $0.time, "axis": $0.axis, "kind": $0.kind.rawValue, "bar": $0.bar.map { $0 as Any } ?? NSNull(),
             "labelFrame": $0.labelFrame.map(rect) ?? NSNull()]
        }
        return ["size": size(r.bounds.size), "cursor": r.cursorName,
                "mode": r.showsBeats ? "beats" : "time",
                "marks": r.showsBeats ? marks : [],
                "pointerAxis": r.pointerAxis.map { Double($0) } ?? NSNull(),
                "playheadAxis": r.playheadAxis.map { Double($0) } ?? NSNull(),
                "lastStartAxis": r.lastStartAxis.map { Double($0) } ?? NSNull(),
                "ticks": ticks] as [String: Any]
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
            "lastStart": state.lastStart, "clearPoint": state.clearPoint, "loop": state.loopEnabled, "follow": state.followPlayhead,
            "followEngaged": state.followEngaged,
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
                "playheadMark": s.playheadMark.map { Double($0) } ?? NSNull(),
                "lastStartMark": s.lastStartMark.map { Double($0) } ?? NSNull()] as [String: Any]
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
        let wf = win.frame
        out["window"] = rect(CGRect(x: wf.minX, y: primary.frame.maxY - wf.maxY, width: wf.width, height: wf.height))
        return out
    }

    private static func menuDump(_ menu: NSMenu?) -> [[String: Any]] {
        guard let menu else { return [] }
        return menu.items.filter { !$0.isSeparatorItem }.map { item in
            var d: [String: Any] = ["title": item.title]
            d["enabled"] = item.isEnabled
            d["checked"] = item.state == .on
            if !item.keyEquivalent.isEmpty {
                var mods: [String] = []
                let m = item.keyEquivalentModifierMask
                if m.contains(.control) { mods.append("ctrl") }
                if m.contains(.option) { mods.append("option") }
                if m.contains(.shift) { mods.append("shift") }
                if m.contains(.command) { mods.append("cmd") }
                d["shortcut"] = (mods + [item.keyEquivalent]).joined(separator: "+")
            }
            if let sub = item.submenu {
                // SwiftUI refreshes menu items (enabled, checkmark) when a menu is about to open.
                sub.delegate?.menuNeedsUpdate?(sub)
                sub.update()
                d["items"] = menuDump(sub)
            }
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
