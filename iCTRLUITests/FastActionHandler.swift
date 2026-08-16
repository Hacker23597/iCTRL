import XCTest

class FastActionHandler {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    func fastTap(x: Double, y: Double) -> ([String: JSONValue]?, JSONRPCError?) {
        let eventRecord = XCSynthesizedEventRecord(name: "Fast Tap")
        let point = CGPoint(x: x, y: y)
        let eventPath = XCPointerEventPath(forTouchAt: point, offset: 0.0)
        eventPath.pressDown(atOffset: 0.0)
        eventPath.liftUp(atOffset: 0.05)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            return (["message": .string("Fast tapped at (\(x), \(y))")], nil)
        } catch {
            return (nil, .serverError("Fast tap failed: \(error.localizedDescription)"))
        }
    }

    /// Two taps back to back, each its own synthesize call and no sleep between.
    /// Spacing is then whatever two IPC round-trips cost — not controlled by us,
    /// which is the whole risk: too slow and the system sees two single taps.
    func fastDoubleTapSeparate(x: Double, y: Double) -> ([String: JSONValue]?, JSONRPCError?) {
        let first = fastTap(x: x, y: y)
        if let err = first.1 { return (nil, err) }
        let second = fastTap(x: x, y: y)
        if let err = second.1 { return (nil, err) }
        return (["message": .string("Fast double tapped at (\(x), \(y)) (two records)")], nil)
    }

    /// Two taps close enough together to read as a double tap.
    ///
    /// Both presses live in ONE event path, so their spacing is set by the
    /// offsets below and nothing else. Sending two separate fastTap calls does
    /// NOT work: each is its own synthesize round-trip, so the real gap is the
    /// sleep plus two IPC hops — past the ~250ms system window, and TikTok read
    /// it as a single tap (the video paused instead of liking).
    func fastDoubleTap(x: Double, y: Double) -> ([String: JSONValue]?, JSONRPCError?) {
        let eventRecord = XCSynthesizedEventRecord(name: "Fast Double Tap")
        let point = CGPoint(x: x, y: y)
        let eventPath = XCPointerEventPath(forTouchAt: point, offset: 0.0)
        eventPath.pressDown(atOffset: 0.0)
        eventPath.liftUp(atOffset: 0.05)
        eventPath.pressDown(atOffset: 0.12)   // 70ms gap — well inside the window
        eventPath.liftUp(atOffset: 0.17)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            return (["message": .string("Fast double tapped at (\(x), \(y))")], nil)
        } catch {
            return (nil, .serverError("Fast double tap failed: \(error.localizedDescription)"))
        }
    }

    /// Press and hold at a point. Same synthesized path as fastTap, just holding
    /// the touch down for `duration` before lifting, so it never pays the
    /// quiescence wait that XCUICoordinate.press(forDuration:) does.
    func fastLongPress(x: Double, y: Double, duration: Double) -> ([String: JSONValue]?, JSONRPCError?) {
        let eventRecord = XCSynthesizedEventRecord(name: "Fast Long Press")
        let point = CGPoint(x: x, y: y)
        let eventPath = XCPointerEventPath(forTouchAt: point, offset: 0.0)
        eventPath.pressDown(atOffset: 0.0)
        // Hold with periodic samples at the SAME point. A path that only presses
        // and lifts carries no events in between, and UIKit's long-press
        // recognizer never sees the touch persist — WeChat opened the chat as if
        // it were a plain tap. Re-stating the position every 100ms keeps the
        // touch alive for the recognizer without moving it (which would cancel).
        var t = 0.1
        while t < duration {
            eventPath.move(to: point, atOffset: t)
            t += 0.1
        }
        eventPath.liftUp(atOffset: duration)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            return (["message": .string("Fast long-pressed at (\(x), \(y)) for \(duration)s")], nil)
        } catch {
            return (nil, .serverError("Fast long press failed: \(error.localizedDescription)"))
        }
    }

    func fastSwipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Double = 0.3) -> ([String: JSONValue]?, JSONRPCError?) {
        let eventRecord = XCSynthesizedEventRecord(name: "Fast Swipe")
        let startPoint = CGPoint(x: fromX, y: fromY)
        let endPoint = CGPoint(x: toX, y: toY)
        let eventPath = XCPointerEventPath(forTouchAt: startPoint, offset: 0.0)
        eventPath.pressDown(atOffset: 0.0)
        eventPath.move(to: endPoint, atOffset: duration)
        eventPath.liftUp(atOffset: duration + 0.05)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            return (["message": .string("Fast swiped from (\(fromX),\(fromY)) to (\(toX),\(toY))")], nil)
        } catch {
            return (nil, .serverError("Fast swipe failed: \(error.localizedDescription)"))
        }
    }

    func fastTypeText(_ text: String) -> ([String: JSONValue]?, JSONRPCError?) {
        let eventRecord = XCSynthesizedEventRecord(name: "Fast Type")
        let eventPath = XCPointerEventPath(forTextInput: ())
        eventPath.typeText(text, atOffset: 0.0, typingSpeed: 60, shouldRedact: false)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            return (["message": .string("Fast typed: \(text)")], nil)
        } catch {
            return (nil, .serverError("Fast type failed: \(error.localizedDescription)"))
        }
    }
}
