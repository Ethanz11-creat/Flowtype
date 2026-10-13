import Cocoa
import CoreGraphics

func click(at point: CGPoint, button: CGMouseButton = .left) {
    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
        moveEvent.post(tap: .cghidEventTap)
    }
    usleep(10000)
    let downType: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp
    if let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button) {
        downEvent.post(tap: .cghidEventTap)
    }
    usleep(50000)
    if let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) {
        upEvent.post(tap: .cghidEventTap)
    }
    usleep(20000)
}

func scroll(at point: CGPoint, deltaY: Int32 = -3) {
    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
        moveEvent.post(tap: .cghidEventTap)
    }
    usleep(10000)
    if let scEv = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) {
        scEv.location = point
        scEv.post(tap: .cghidEventTap)
    }
    usleep(80000)
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("Usage"); exit(1) }
let cmd = args[1]
switch cmd {
case "click":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { print("Bad coords"); exit(1) }
    let button: CGMouseButton = (args.count > 4 && args[4] == "right") ? .right : .left
    click(at: CGPoint(x: x, y: y), button: button)
    print("OK click",x,y)
case "scroll":
    guard args.count >= 5, let x = Double(args[2]), let y = Double(args[3]), let dY = Int32(args[4]) else { print("Bad args"); exit(1) }
    scroll(at: CGPoint(x: x, y: y), deltaY: dY)
    print("OK scroll",x,y,dY)
default:
    print("Unknown"); exit(1)
}
