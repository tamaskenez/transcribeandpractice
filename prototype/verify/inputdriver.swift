// Posts synthetic input events (Quartz) for milestone 3 verification. Needs Accessibility
// permission for the terminal. Build: swiftc -O verify/inputdriver.swift -o verify/out/m3/inputdriver
// Reads commands from stdin, one per line (coordinates: global screen points, top-left origin):
//   move x y
//   click x y [mods]                      mods: comma list of shift,option,cmd or "-"
//   drag x1 y1 x2 y2 [mods] [left|middle]
//   scroll x y dx dy [mods]               pixel units; positive dy = wheel up
//   scrollf x y dx dy                     a continuous (trackpad-like) scroll with fractional deltas
//   magnify x y m [steps]                 trackpad pinch, total magnification m
//   key escape|space|left|right|down|b|backspace [mods]
//   press <pid> <title>                   press a toolbar button via Accessibility
//   enabled <pid> <title>                 print the button's AXEnabled
//   front <pid>                           make the app frontmost via Accessibility
//   focus <pid> <title>                   focus a text field via Accessibility
//   type <text>                           type the text (unicode key events)
//   down x y / dragto x y / up x y        a left-button drag in separate steps (dragto: 10 drag events
//                                         from the last position)
//   sleep ms
import ApplicationServices
import Foundation

func flags(_ s: String?) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in (s ?? "-").split(separator: ",") {
        switch m {
        case "shift": f.insert(.maskShift)
        case "option": f.insert(.maskAlternate)
        case "cmd": f.insert(.maskCommand)
        default: break
        }
    }
    return f
}

func pause(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

func post(_ type: CGEventType, _ p: CGPoint, _ f: CGEventFlags = [], button: CGMouseButton = .left) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    e.flags = f
    if button == .center { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
    e.post(tap: .cghidEventTap)
}

func setModifiers(_ f: CGEventFlags) {
    // Key state for the modifiers, so NSEvent.modifierFlags agree with the event flags.
    guard let e = CGEvent(source: nil) else { return }
    e.type = .flagsChanged
    e.flags = f
    e.post(tap: .cghidEventTap)
}

func axButton(pid: pid_t, title: String) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        if let role = attr(el, kAXRoleAttribute) as? String, [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXTextFieldRole].contains(role) {
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                if let s = attr(el, key) as? String, s == title { return el }
            }
        }
        guard depth < 12, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for k in kids { if let r = search(k, depth: depth + 1) { return r } }
        return nil
    }
    return search(app, depth: 0)
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("inputdriver: no Accessibility permission\n".utf8))
    exit(2)
}

var last = CGPoint.zero
while let line = readLine() {
    let a = line.split(separator: " ").map(String.init)
    guard let cmd = a.first else { continue }
    let d = { (i: Int) in Double(a[i])! }
    switch cmd {
    case "move":
        post(.mouseMoved, CGPoint(x: d(1), y: d(2)))
    case "click":
        let p = CGPoint(x: d(1), y: d(2)), f = flags(a.count > 3 ? a[3] : nil)
        setModifiers(f)
        post(.mouseMoved, p); pause(30)
        post(.leftMouseDown, p, f); pause(30)
        post(.leftMouseUp, p, f); pause(30)
        setModifiers([])
    case "drag":
        let p1 = CGPoint(x: d(1), y: d(2)), p2 = CGPoint(x: d(3), y: d(4))
        let f = flags(a.count > 5 ? a[5] : nil)
        let middle = a.count > 6 && a[6] == "middle"
        let (down, dragged, up): (CGEventType, CGEventType, CGEventType) = middle
            ? (.otherMouseDown, .otherMouseDragged, .otherMouseUp) : (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
        let button: CGMouseButton = middle ? .center : .left
        setModifiers(f)
        post(.mouseMoved, p1); pause(30)
        post(down, p1, f, button: button); pause(30)
        let steps = 20
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            post(dragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t), f, button: button)
            pause(10)
        }
        pause(30)
        post(up, p2, f, button: button); pause(30)
        setModifiers([])
    case "scroll":
        let p = CGPoint(x: d(1), y: d(2)), f = flags(a.count > 5 ? a[5] : nil)
        setModifiers(f)
        post(.mouseMoved, p); pause(30)
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: Int32(d(4)), wheel2: Int32(d(3)), wheel3: 0) {
            e.flags = f
            e.location = p
            e.post(tap: .cghidEventTap)
        }
        pause(30)
        setModifiers([])
    case "scrollp":
        // scrollp x y dx dy phase [flags]: a continuous (trackpad-like) scroll event with a gesture
        // phase (1 began, 2 changed, 4 ended, 0 none).
        let p = CGPoint(x: d(1), y: d(2)), f = flags(a.count > 6 ? a[6] : nil)
        setModifiers(f)
        post(.mouseMoved, p, f); pause(20)
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: Int32(d(4)), wheel2: Int32(d(3)), wheel3: 0) {
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(d(5)))
            e.flags = f
            e.location = p
            e.post(tap: .cghidEventTap)
        }
        pause(30)
        if d(5) == 0 || d(5) == 4 { setModifiers([]) }
    case "scrollf":
        let p = CGPoint(x: d(1), y: d(2))
        post(.mouseMoved, p); pause(30)
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) {
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: d(4))
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: d(3))
            e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: d(4))
            e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: d(3))
            e.location = p
            e.post(tap: .cghidEventTap)
        }
        pause(30)
    case "magnify":
        // Undocumented gesture event fields (as used by gesture-synthesis tools):
        // 55 = event type (29 gesture), 110 = HID gesture type (8 zoom), 113 = magnification,
        // 132 = phase (1 began, 2 changed, 4 ended).
        let p = CGPoint(x: d(1), y: d(2)), total = d(3), steps = a.count > 4 ? Int(a[4])! : 10
        post(.mouseMoved, p); pause(30)
        func gesture(_ m: Double, phase: Int64) {
            guard let e = CGEvent(source: nil) else { return }
            e.type = CGEventType(rawValue: 29)!
            e.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
            e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
            e.setDoubleValueField(CGEventField(rawValue: 113)!, value: m)
            e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
            e.location = p
            e.post(tap: .cghidEventTap)
            pause(15)
        }
        let per = total / Double(steps)
        gesture(0, phase: 1)
        for _ in 0..<steps { gesture(per, phase: 2) }
        gesture(0, phase: 4)
    case "key":
        let codes: [String: CGKeyCode] = ["escape": 53, "space": 49, "left": 123, "right": 124, "down": 125, "b": 11, "backspace": 51, "a": 0, "return": 36]
        if let code = codes[a[1]] {
            let f = flags(a.count > 2 ? a[2] : nil)
            setModifiers(f)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                e?.flags = f
                e?.post(tap: .cghidEventTap); pause(20)
            }
            setModifiers([])
        }
    case "press", "enabled":
        let title = a[2...].joined(separator: " ")
        guard let b = axButton(pid: pid_t(a[1])!, title: title) else { print("notfound"); break }
        if cmd == "press" {
            print(AXUIElementPerformAction(b, kAXPressAction as CFString) == .success ? "pressed" : "failed")
        } else {
            var v: AnyObject?
            AXUIElementCopyAttributeValue(b, kAXEnabledAttribute as CFString, &v)
            print((v as? Bool) == true ? "true" : "false")
        }
    case "focus":
        let title = a[2...].joined(separator: " ")
        guard let el = axButton(pid: pid_t(a[1])!, title: title) else { print("notfound"); break }
        print(AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success ? "focused" : "failed")
    case "type":
        let text = a.count > 1 ? a[1...].joined(separator: " ") : ""
        for ch in text.utf16 {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                var c = ch
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e?.post(tap: .cghidEventTap); pause(20)
            }
        }
    case "front":
        let app = AXUIElementCreateApplication(pid_t(a[1])!)
        print(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success ? "ok" : "failed")
    case "down":
        let p = CGPoint(x: d(1), y: d(2))
        post(.mouseMoved, p); pause(30)
        post(.leftMouseDown, p); pause(30)
        last = p
    case "dragto":
        let p = CGPoint(x: d(1), y: d(2))
        last = CGEvent(source: nil)?.location ?? last // the pointer, also across driver runs
        for i in 1...10 {
            let t = Double(i) / 10
            post(.leftMouseDragged, CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t)); pause(10)
        }
        last = p
    case "up":
        post(.leftMouseUp, CGPoint(x: d(1), y: d(2))); pause(30)
    case "sleep":
        pause(Int(a[1])!)
    default:
        FileHandle.standardError.write(Data("inputdriver: unknown command \(cmd)\n".utf8))
    }
    pause(20)
}
