import ApplicationServices
import CoreGraphics
import Foundation

// axdrive: the screenshot harness's hands. It reaches a Share Bar state the way a person
// does: a real mouse click at the centre of a control found in the app's own Accessibility
// tree, or a real key press. It never sets state inside the app (SPEC-009 DEC-56).
//
//   axdrive trusted
//   axdrive find   <pid> <name> [timeout-seconds]   exit 0 when the control exists, 3 when not
//   axdrive click  <pid> <name> [timeout-seconds]   real click at the control's centre
//   axdrive key    <name> [cmd] [opt] [ctrl] [shift]
//   axdrive window <pid>                            frontmost window id of the app, for screencapture -l
//
// <name> is `status-item` (the app's menu bar item) or a title, description or identifier
// in the app's tree: an exact match first, then a title that starts with it.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let posValue = attribute(element, kAXPositionAttribute),
          let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func roots(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 2)
    var list: [AXUIElement] = []
    if let extras = attribute(app, "AXExtrasMenuBar") { list.append(extras as! AXUIElement) }
    list.append(app)
    return list
}

func statusItem(_ pid: pid_t) -> AXUIElement? {
    guard let extras = attribute(AXUIElementCreateApplication(pid), "AXExtrasMenuBar") else { return nil }
    return children(extras as! AXUIElement).first
}

func locate(_ pid: pid_t, _ name: String) -> AXUIElement? {
    if name == "status-item" { return statusItem(pid) }
    var prefixHit: AXUIElement?
    var queue = roots(pid)
    var visited = 0
    while !queue.isEmpty, visited < 4000 {
        let element = queue.removeFirst()
        visited += 1
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier"].compactMap { text(element, $0) }
        if labels.contains(name) { return element }
        if prefixHit == nil, let title = text(element, kAXTitleAttribute), title.hasPrefix(name) { prefixHit = element }
        queue.append(contentsOf: children(element))
    }
    return prefixHit
}

func waitFor(_ pid: pid_t, _ name: String, _ seconds: Double) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let element = locate(pid, name) { return element }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return nil
}

func post(_ type: CGEventType, at point: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: 1)
    event?.post(tap: .cghidEventTap)
}

func click(_ element: AXUIElement) -> Bool {
    guard let box = frame(element), box.width > 0, box.height > 0 else { return false }
    let point = CGPoint(x: box.midX, y: box.midY)
    // Hover first and let the control highlight: a click that lands before the window has
    // seen the pointer is dropped by some panels (an NSAlert's button).
    post(.mouseMoved, at: point)
    Thread.sleep(forTimeInterval: 0.3)
    post(.mouseMoved, at: CGPoint(x: point.x + 1, y: point.y))
    Thread.sleep(forTimeInterval: 0.1)
    post(.leftMouseDown, at: point)
    Thread.sleep(forTimeInterval: 0.1)
    post(.leftMouseUp, at: point)
    return true
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "a": 0, "s": 1, "d": 2, "f": 3, "c": 8, "v": 9, "z": 6, "q": 12, "w": 13,
]

func press(_ name: String, modifiers: [String]) -> Bool {
    guard let code = keyCodes[name] else { return false }
    var flags: CGEventFlags = []
    for modifier in modifiers {
        switch modifier {
        case "cmd": flags.insert(.maskCommand)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        default: return false
        }
    }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
    return true
}

/// The frontmost on-screen window the app owns that is bigger than the status item.
func frontWindow(_ pid: pid_t) -> Int? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for entry in info where (entry[kCGWindowOwnerPID as String] as? Int32) == pid {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"], width * height > 2000 else { continue }
        return entry[kCGWindowNumber as String] as? Int
    }
    return nil
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: axdrive trusted|find|click|key|window ...", code: 2) }

switch args[1] {
case "trusted":
    print(AXIsProcessTrusted())
    exit(AXIsProcessTrusted() ? 0 : 4)
case "find", "click":
    guard args.count >= 4, let pid = Int32(args[2]) else { fail("usage: axdrive \(args[1]) <pid> <name> [seconds]", code: 2) }
    guard AXIsProcessTrusted() else { fail("Accessibility is not granted to this terminal", code: 4) }
    let name = args[3]
    let seconds = args.count > 4 ? (Double(args[4]) ?? 3) : 3
    guard let element = waitFor(pid, name, seconds) else { fail("missing control: \(name)", code: 3) }
    if args[1] == "click" {
        guard click(element) else { fail("control has no on-screen frame: \(name)", code: 3) }
        // A panel's button can drop a click that lands while the app is not yet active (an
        // NSAlert on another display). If the button is still there after the click, press
        // it through its own Accessibility action: still the control's own handler, no state set.
        if text(element, kAXRoleAttribute) == kAXButtonRole as String {
            Thread.sleep(forTimeInterval: 0.5)
            if frame(element) != nil { AXUIElementPerformAction(element, kAXPressAction as CFString) }
        }
    }
case "dump":
    guard args.count >= 3, let pid = Int32(args[2]) else { fail("usage: axdrive dump <pid>", code: 2) }
    func dump(_ element: AXUIElement, depth: Int) {
        guard depth < 6 else { return }
        let role = text(element, kAXRoleAttribute) ?? "?"
        let title = text(element, kAXTitleAttribute) ?? text(element, kAXDescriptionAttribute) ?? ""
        print(String(repeating: "  ", count: depth) + "\(role) \"\(title)\" \(frame(element).map { "\($0)" } ?? "")")
        for child in children(element) { dump(child, depth: depth + 1) }
    }
    let app = AXUIElementCreateApplication(pid)
    var names: CFArray?
    AXUIElementCopyAttributeNames(app, &names)
    print("app attributes: \((names as? [String]) ?? [])")
    for root in roots(pid) { dump(root, depth: 0) }
case "key":
    guard args.count >= 3 else { fail("usage: axdrive key <name> [cmd] [opt] [ctrl] [shift]", code: 2) }
    guard AXIsProcessTrusted() else { fail("Accessibility is not granted to this terminal", code: 4) }
    if !press(args[2], modifiers: Array(args.dropFirst(3))) { fail("unknown key: \(args[2])", code: 2) }
case "window":
    guard args.count >= 3, let pid = Int32(args[2]) else { fail("usage: axdrive window <pid>", code: 2) }
    guard let id = frontWindow(pid) else { fail("no on-screen window for pid \(pid)", code: 3) }
    print(id)
default:
    fail("unknown command: \(args[1])", code: 2)
}
