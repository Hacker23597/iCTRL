import Foundation
import CoreGraphics

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}
let size = CGSize(width: 390, height: 844)
/// Stands in for ActionHandler.validateCoordinate: same bounds rule, same code.
func onScreen(_ point: CGPoint, _ index: Int) -> JSONRPCError? {
    point.x >= 0 && point.y >= 0 && point.x <= size.width && point.y <= size.height ? nil
        : JSONRPCError(code: -32602, message: "drag point \(index) out of bounds", data: nil)
}
func parse(_ params: [String: JSONValue]) -> (ContinuousDragPath?, JSONRPCError?) {
    ContinuousDragPath.parse(params, checkPoint: onScreen)
}
func point(_ x: Double, _ y: Double) -> JSONValue { .object(["x": .double(x), "y": .double(y)]) }
let valid: [JSONValue] = [point(50, 200), point(150, 200), point(150, 300)]
func rejected(_ params: [String: JSONValue]) {
    let (path, error) = parse(params)
    check(path == nil && error?.code == -32602, "Invalid path accepted: \(params)")
}

// Parsing and sampling: one move per waypoint, equal time per segment.
let (parsed, error) = parse(["points": .array(valid)])
check(error == nil && parsed != nil, "Valid path rejected")
let path = parsed!
check(path.duration == 1, "Unexpected default duration")
check(path.points == [CGPoint(x: 50, y: 200), CGPoint(x: 150, y: 200), CGPoint(x: 150, y: 300)], "Waypoints changed")
check(path.samples.count == path.points.count - 1, "Not one move per waypoint after the press")
check(path.samples.map(\.point) == Array(path.points.dropFirst()), "Moves do not follow the waypoints exactly")
check(path.samples[0].offset == 0.5 && path.samples[1].offset == 1.0, "Segments not equally timed")
check(path.samples.last!.offset == path.duration, "Last move not at the full duration")

// A repeated waypoint is a later move to the same point: the finger holds.
let (hold, _) = parse(["points": .array([point(10, 10), point(100, 10), point(100, 10), point(100, 90)]),
                       "duration": .double(1.5)])
check(hold!.samples.map(\.offset) == [0.5, 1.0, 1.5], "Hold not timed as its own segment")
check(hold!.samples[0].point == hold!.samples[1].point, "Hold moved the finger")

for raw in [JSONValue.null, .object([:]), .string("bad"), .array([]), .array([point(1, 1)]), .array(Array(repeating: point(1, 1), count: 65))] {
    rejected(["points": raw])
}
for raw in [JSONValue.string("1"), .bool(true), .null, .double(.nan), .double(.infinity), .double(-1), .double(0), .double(0.099), .double(10.001)] {
    rejected(["points": .array(valid), "duration": raw])
}
for invalid in [point(-1, 1), point(391, 1), point(1, -1), point(1, 845), point(.nan, 1), point(1, .infinity), .null, .object(["x": .int(1)]), .object(["x": .bool(true), "y": .int(1)]), .object(["x": .string("1"), "y": .int(1)])] {
    rejected(["points": .array([point(1, 1), invalid])])
}
for key in ["from_x", "from_y", "to_x", "to_y", "from_ref", "to_ref"] {
    // Even malformed/null endpoint fields must not silently coexist with points.
    rejected(["points": .array(valid), key: .null])
    rejected(["points": .array(valid), key: .string("bad")])
}

// Bounds come from the caller's rule, checked for every point with its index.
var seen: [Int] = []
let (_, boundsError) = ContinuousDragPath.parse(["points": .array([point(1, 1), point(2, 2), point(999, 3), point(4, 4)])]) { p, i in
    seen.append(i)
    return onScreen(p, i)
}
check(boundsError?.message == "drag point 2 out of bounds", "Caller's bounds error not returned as is")
check(seen == [0, 1, 2], "Bounds not checked in order, or checked past the first failure")

for duration in [0.1, 10.0] {
    let (path, error) = parse(["points": .array(Array(repeating: point(390, 844), count: 64)), "duration": .double(duration)])
    check(error == nil && path != nil, "Valid boundary rejected")
    let samples = path!.samples
    check(samples.count == 63, "Not one move per waypoint at the 64-point limit")
    check(samples.allSatisfy { $0.point == CGPoint(x: 390, y: 844) }, "Hold moved")
    check(samples.last!.offset == duration, "Boundary duration drift")
    check(zip(samples, samples.dropFirst()).allSatisfy { $0.offset < $1.offset }, "Repeated waypoint offsets invalid")
}

// Waypoints for the alert and anti-bot checks: every well-formed point, in order.
let mixed: [String: JSONValue] = ["points": .array([point(50, 200), .null, point(.nan, 1), point(300, 600)])]
check(ContinuousDragPath.waypoints(mixed) == [CGPoint(x: 50, y: 200), CGPoint(x: 300, y: 600)],
      "Anti-bot check would miss a later waypoint")
check(ContinuousDragPath.waypoints(["points": .array([point(.nan, 1)])]).isEmpty, "Nonfinite waypoint accepted")
check(ContinuousDragPath.waypoints(nil).isEmpty, "Endpoint drag reported waypoints")

// Watchdog: duration × 1.25 + settle cap + 3s, never below the default.
func budget(_ params: [String: JSONValue]?) -> TimeInterval { ContinuousDragPath.rpcBudget(params, defaultBudget: 6) }
check(budget(["points": .array(valid), "duration": .double(10)]) == 17.5, "10s path budget wrong")
check(budget(["points": .array(valid), "duration": .double(10), "settle_timeout": .double(3)]) == 18.5, "Settle cap not added")
check(budget(["points": .array(valid), "duration": .double(10), "settle_timeout": .double(60)]) == 18.5, "Settle cap not clamped")
check(budget(["points": .array(valid), "duration": .double(10), "settle_timeout": .double(.nan)]) == 18.5, "Nonfinite settle unbounded")
check(budget(["points": .array(valid)]) == 6.25, "Default path budget wrong")
check(budget(["points": .array(valid), "duration": .double(0.1)]) == 6, "Budget fell below the default")
check(budget(nil) == 6, "Legacy watchdog changed")
check(budget(["duration": .double(10)]) == 6, "Endpoint watchdog changed")
check(budget(["points": .array(valid), "duration": .double(.infinity)]) == 6, "Unbounded watchdog")

let legacy = ActionCommand(method: "drag", params: ["from_x": .int(1), "from_y": .int(2), "to_x": .int(3), "to_y": .int(4)])
check(legacy.dragPathParams == nil && legacy.fromX == 1 && legacy.toY == 4, "Legacy decoding changed")
let unrelated = ActionCommand(method: "tap", params: ["points": .array(valid)])
check(unrelated.dragPathParams == nil, "Path arguments changed another method")
let malformed = ActionCommand(method: "drag", params: ["points": .null])
check(malformed.dragPathParams != nil, "Explicit null path silently falls back to endpoints")
let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(#"{"jsonrpc":"2.0","method":"drag","params":{"points":[{"x":50,"y":200},{"x":150,"y":200},{"x":150,"y":300}],"duration":1.2},"id":1}"#.utf8))
let command = ActionCommand(method: request.method, params: request.params)
let (decoded, decodeError) = parse(command.dragPathParams!)
check(decodeError == nil && decoded?.duration == 1.2 && decoded?.points.count == 3, "RPC path decoding failed")
print("ContinuousDragPath: \(checks) checks passed")
