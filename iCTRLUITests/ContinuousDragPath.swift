import Foundation

/// A single finger following waypoints; independent of XCTest so validation and
/// timing can be tested without injecting touches into a device.
struct ContinuousDragPath {
    struct Sample {
        let point: CGPoint
        let offset: TimeInterval
    }

    let points: [CGPoint]
    let duration: TimeInterval

    static let defaultDuration: TimeInterval = 1.0
    static let durationRange: ClosedRange<TimeInterval> = 0.1...10.0

    /// Bounds are checked by `checkPoint` (the caller's on-screen rule, so a
    /// path and an endpoint drag reject the same coordinates the same way); it
    /// gets each point with its index and returns the error to reply with.
    static func parse(_ params: [String: JSONValue],
                      checkPoint: (CGPoint, Int) -> JSONRPCError?)
        -> (ContinuousDragPath?, JSONRPCError?) {
        func invalid(_ message: String) -> (ContinuousDragPath?, JSONRPCError?) {
            (nil, JSONRPCError(code: -32602, message: message, data: nil))
        }
        guard case .array(let values)? = params["points"], (2...64).contains(values.count) else {
            return invalid("drag points requires an array of 2...64 {x,y} objects")
        }
        let endpoints = ["from_x", "from_y", "to_x", "to_y", "from_ref", "to_ref"]
        guard !endpoints.contains(where: { params[$0] != nil }) else {
            return invalid("drag points cannot be combined with endpoint coordinates or refs")
        }
        let duration: Double
        if let raw = params["duration"] {
            guard let value = raw.doubleValue else { return invalid("drag points duration must be a number") }
            duration = value
        } else {
            duration = defaultDuration
        }
        guard duration.isFinite, durationRange.contains(duration) else {
            return invalid("drag points duration must be finite and between 0.1 and 10 seconds")
        }
        var points: [CGPoint] = []
        for (index, value) in values.enumerated() {
            guard let item = value.objectValue, let x = item["x"]?.doubleValue,
                  let y = item["y"]?.doubleValue, x.isFinite, y.isFinite else {
                return invalid("Each drag point requires finite numeric x and y")
            }
            let point = CGPoint(x: x, y: y)
            if let error = checkPoint(point, index) { return (nil, error) }
            points.append(point)
        }
        return (ContinuousDragPath(points: points, duration: duration), nil)
    }

    /// Every well-formed waypoint, for checks that run before parse() (system
    /// alert routing, the anti-bot guard). Malformed entries are skipped here;
    /// parse() rejects the request before any touch is injected.
    static func waypoints(_ params: [String: JSONValue]?) -> [CGPoint] {
        guard case .array(let values)? = params?["points"] else { return [] }
        return values.compactMap { value in
            guard let item = value.objectValue,
                  let x = item["x"]?.doubleValue, let y = item["y"]?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    /// A legitimate long path must not time out while its touch is still down.
    /// Playback can run late on a busy device, so the gesture gets a quarter
    /// more than its nominal length, then the settle cap and 3s of overhead.
    static func rpcBudget(_ params: [String: JSONValue]?, defaultBudget: TimeInterval) -> TimeInterval {
        guard case .array? = params?["points"] else { return defaultBudget }
        let duration = params?["duration"]?.doubleValue ?? defaultDuration
        guard duration.isFinite, durationRange.contains(duration) else { return defaultBudget }
        let settle = min(max(params?["settle_timeout"]?.doubleValue ?? 2, 0), 3)
        return max(defaultBudget, duration * 1.25 + (settle.isFinite ? settle : 3) + 3)
    }

    /// One move per waypoint, equal time per segment: XCTest interpolates the
    /// finger between moves itself, so corners land exactly and playback keeps
    /// to the requested duration. A repeated waypoint is a move to the same
    /// point at a later offset, which holds the finger there.
    var samples: [Sample] {
        let last = points.count - 1
        let segmentDuration = duration / Double(last)
        return points.indices.dropFirst().map {
            Sample(point: points[$0], offset: $0 == last ? duration : Double($0) * segmentDuration)
        }
    }
}
