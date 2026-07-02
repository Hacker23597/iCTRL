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
