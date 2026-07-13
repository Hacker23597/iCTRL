import XCTest
import UIKit

class ActionHandler {
    private let app: XCUIApplication
    private let fastHandler: FastActionHandler

    /// Last app we brought to the foreground via launch_app/activate_app.
    /// Used as a fallback for page_source when private-API detection fails.
    private var lastForegroundBundleId: String?

    /// A resolvable element reference. Re-queries the LIVE tree each time it's
    /// used, so it stays valid across small layout changes (unlike a coordinate).
    struct ElementRef {
        let bundleId: String?
        let match: Match
        enum Match {
            case identifier(String)          // exact accessibility id
            case exactLabel(String)          // label == value
            case containsLabel(String)       // label CONTAINS[c] value
        }
        let elementType: String?             // optional type filter (button/…)
        let index: Int                       // which match (usually 0)
        let createdAt: TimeInterval          // monotonic creation time
    }

    /// Refs expire after this many seconds; also capped to `refMaxCount`.
    private static let refTTL: TimeInterval = 3600      // 1 hour
    private static let refMaxCount = 500

    private var refStore: [String: ElementRef] = [:]
    private var refCounter = 0

    private var nowMonotonic: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func makeRef(_ ref: ElementRef) -> String {
        pruneRefs()
        refCounter += 1
        let id = "el_\(refCounter)"
        refStore[id] = ref
        return id
    }

    /// Drop expired refs (TTL) and enforce the count cap (oldest-first).
    private func pruneRefs() {
        let cutoff = nowMonotonic - Self.refTTL
        refStore = refStore.filter { $0.value.createdAt >= cutoff }
        if refStore.count > Self.refMaxCount {
            // Remove the oldest overflow (createdAt ascending).
            let overflow = refStore.count - Self.refMaxCount
            let oldest = refStore.sorted { $0.value.createdAt < $1.value.createdAt }
                                 .prefix(overflow).map { $0.key }
            for k in oldest { refStore.removeValue(forKey: k) }
        }
    }

    /// Resolve a stored ref back to a live XCUIElement (nil if gone/expired).
    private func resolveRef(_ refId: String) -> XCUIElement? {
        guard let ref = refStore[refId] else { return nil }
        // Expired?
        if nowMonotonic - ref.createdAt > Self.refTTL {
            refStore.removeValue(forKey: refId)
            return nil
        }
        let target: XCUIApplication = ref.bundleId.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        let base = elementQuery(in: target, type: ref.elementType)
        let query: XCUIElementQuery
        switch ref.match {
        case .identifier(let v):    query = base.matching(identifier: v)
        case .exactLabel(let v):    query = base.matching(NSPredicate(format: "label == %@", v))
        case .containsLabel(let v): query = base.matching(NSPredicate(format: "label CONTAINS[c] %@", v))
        }
        let el = query.element(boundBy: ref.index)
        return el.exists ? el : nil
    }

    private func elementQuery(in target: XCUIApplication, type: String?) -> XCUIElementQuery {
        switch type?.lowercased() {
        case "button":                  return target.buttons
        case "textfield", "text_field": return target.textFields
        case "textview", "text_view":   return target.textViews
        case "label", "static_text":    return target.staticTexts
        case "image":                   return target.images
        case "cell":                    return target.cells
        case "switch":                  return target.switches
        case "icon":                    return target.icons
        default:                        return target.descendants(matching: .any)
        }
    }

    init(app: XCUIApplication) {
        self.app = app
        self.fastHandler = FastActionHandler(app: app)
    }

    /// Resolve which app subsequent actions target.
    ///
    /// Priority (per user design): the app we most recently OPENED via
    /// launch_app/activate_app is the "sticky target" — element queries and taps
    /// stay bound to it even if the user later switches to another app in the
    /// foreground. Only when we've never opened an app do we fall back to the
    /// live-detected foreground app. An explicit bundle_id on the call overrides
    /// everything (handled by callers passing it through).
    private func resolveForegroundBundleId() -> String? {
        if let bound = boundBundleId, !bound.isEmpty {
            return bound
        }
        // Never opened anything explicitly — use the live foreground app.
        if let bid = ForegroundApp.currentBundleID(), !bid.isEmpty {
            return bid
        }
        return lastForegroundBundleId
    }

    /// The sticky target app: the last one opened via launch_app/activate_app.
    /// nil until the caller opens an app, after which every action binds here
    /// unless the call passes an explicit bundle_id.
    private var boundBundleId: String?

    // MARK: - Screen Geometry (for progressive disclosure)

    /// Cached point size. Reading `app.frame` triggers XCUITest quiescence waiting
    /// (waits for the UI to be idle), which on animation-heavy apps can take many
    /// seconds or time out. The screen size never changes during a session (rotation
    /// aside), so we fetch it once lazily and reuse it — keeping the hot path (tap/
    /// swipe validation + hint) free of quiescence.
    private var cachedPointSize: CGRect?

    /// Logical point size of the screen — the coordinate space ALL tap/swipe/drag use.
    /// Fetched once, then cached, to avoid repeated quiescence waits.
    private var pointSize: CGRect {
        if let cached = cachedPointSize { return cached }
        let frame = app.frame
        cachedPointSize = frame
        return frame
    }

    /// Device scale factor (points → pixels). UIScreen access does NOT trigger quiescence.
    private var scale: Double { Double(UIScreen.main.scale) }

    /// Validate a coordinate is inside the tappable point-space.
    /// Uses the cached size — no quiescence wait.
    private func validateCoordinate(x: Double, y: Double, context: String) -> JSONRPCError? {
        let size = pointSize
        let w = size.width, h = size.height
        guard x >= 0, y >= 0, x <= w, y <= h else {
            return JSONRPCError(
                code: -32602,
                message: "\(context): coordinate (\(x), \(y)) is out of bounds. " +
                    "Valid tap range is x∈[0,\(Int(w))], y∈[0,\(Int(h))] in POINTS (not pixels). " +
                    "If you computed this from a screenshot, divide pixel coordinates by scale=\(scale) first.",
                data: [
                    "point_width": .double(w),
                    "point_height": .double(h),
                    "scale": .double(scale),
                ]
            )
        }
        return nil
    }

    /// A compact hint object attached to spatial-action responses so the model
    /// keeps the coordinate space in context without re-querying device_info.
    /// Uses the cached size — no quiescence wait.
    private var coordinateHint: JSONValue {
        let size = pointSize
        return .object([
            "coordinate_space": .string("points"),
            "point_width": .double(size.width),
            "point_height": .double(size.height),
            "scale": .double(scale),
        ])
    }

    /// Methods that operate on the on-screen UI. Before running any of these we
    /// make sure the sticky target app (from launch_app/activate_app) is actually
    /// in the foreground — so a coordinate tap / element query lands on it even if
    /// the user drifted to another app. No-op when nothing is bound or the target
    /// is already foreground.
    // Methods that we re-focus the bound app for before running. Only INTERACTIONS
    // are here. Deliberately EXCLUDED:
    //  - 'type' — re-activating dismisses the keyboard / drops focus.
    //  - 'page_source'/'screenshot'/'find_element' — READ-ONLY. WDA doesn't
    //    activate the app to read its source; it just resolves the active app and
    //    snapshots. Activating here triggers a foreground transition/animation that
    //    the snapshot then blocks on (observed 13-16s snapshot hangs). Reads use the
    //    resolved target app WITHOUT forcing it forward.
    private static let uiActionMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "scroll", "drag",
        "page", "page_down", "page_up",
        "scroll_to_element", "scroll_to", "tap_element",
    ]

    /// XCUIApplication.State raw values (see ForegroundApp.appStateForBundleID).
    private enum AppState: Int {
        case unknown = 0, notRunning = 1, backgroundSuspended = 2
        case background = 3, foreground = 4
    }

    /// Prepare the target app for a UI action, mirroring WebDriverAgent's
    /// `activeApplication` logic but returning an AI-friendly diagnostic instead
    /// of silently doing the wrong thing:
    ///   - if a SYSTEM ALERT is up, stop and tell the caller to handle it first;
    ///   - if the bound app has CRASHED/EXITED, stop and tell the caller to relaunch;
    ///   - if it's merely backgrounded, bring it forward (bounded, exception-safe);
    ///   - if it's already frontmost (or was just launched), no-op.
    /// Returns an error to abort the action, or nil to proceed. `note` (if set) is
    /// attached to the successful response so the model learns what happened.
    private func ensureBoundAppForeground(allowOverAlert: Bool = false) -> (error: JSONRPCError?, note: String?) {
        // A system alert (permission prompt, etc.) sits above the app. A ref/
        // element interaction on the bound app underneath would misfire, so we
        // surface guidance — BUT a raw coordinate tap can legitimately target the
        // alert's own button, so allowOverAlert lets those through.
        if !allowOverAlert, ForegroundApp.hasSystemAlert() {
            return (JSONRPCError(code: -32000, message:
                "A system alert/permission dialog is currently on screen, covering the app. To tap ITS buttons, " +
                "use raw coordinates: page_source{bundle_id:\"com.apple.springboard\"} to read the alert's button " +
                "frames, then tap{x,y} (coordinate taps are allowed to hit the alert). Ref/element actions on the " +
                "app underneath won't work until the alert is dismissed.", data: nil), nil)
        }

        guard let bound = boundBundleId, !bound.isEmpty else { return (nil, nil) }

        // Just opened/activated it — skip the (possibly slow) re-check; the app is
        // already coming to the front. Avoids a redundant ~3-5s activate right
        // after launch_app.
        if nowMonotonic - lastBoundActivateAt < 4.0 { return (nil, nil) }

        // If it's already frontmost, nothing to do.
        if ForegroundApp.currentBundleID() == bound { return (nil, nil) }

        // Check the bound app's actual state before touching it. (WDA throws
        // FBApplicationCrashedException here; we return a clear, recoverable error.)
        let state = AppState(rawValue: ForegroundApp.appState(forBundleID: bound)) ?? .unknown
        switch state {
        case .notRunning:
            return (JSONRPCError(code: -32001, message:
                "The bound app '\(bound)' is no longer running (it was closed or the system reclaimed it). " +
                "Re-open it with launch_app{bundle_id:\"\(bound)\"} before continuing. " +
                "(Actions stay bound to the app you launched; when it exits you must relaunch.)", data: nil), nil)
        case .background, .backgroundSuspended, .unknown:
            // Bring it forward — exception-safe, bounded.
            _ = runWithTimeout(seconds: 3) {
                _ = ForegroundApp.safeActivateBundleID(bound)
            }
            lastBoundActivateAt = nowMonotonic
            usleep(300_000)  // let the switch settle
            return (nil, "Re-focused '\(bound)' (it had gone to the background) before this action.")
        case .foreground:
            return (nil, nil)
        }
    }

    /// Monotonic time of the last activate of the bound app (launch/activate or a
    /// foreground-enforcement). Used to skip redundant re-activations.
    private var lastBoundActivateAt: TimeInterval = 0

    func dispatch(method: String, params: [String: JSONValue]?) -> ([String: JSONValue]?, JSONRPCError?) {
        let cmd = ActionCommand(method: method, params: params)

        // Keep the sticky target app in front for UI actions — unless the caller
        // passed an explicit bundle_id for this call (they want that app instead).
        var foregroundNote: String? = nil
        if Self.uiActionMethods.contains(method), cmd.bundleId == nil {
            // A raw coordinate tap/swipe (x,y given) synthesizes a touch at that
            // exact screen point regardless of which layer owns it — so it CAN hit
            // a system alert's button. Don't block those on an alert; only block
            // ref/element interactions on the bound app (those act on the app
            // underneath and would misfire while an alert covers it).
            let hasCoords = cmd.x != nil && cmd.y != nil
            let hasCoordPair = cmd.fromX != nil && cmd.fromY != nil
            let coordinateBased = hasCoords || hasCoordPair
            let prep = ensureBoundAppForeground(allowOverAlert: coordinateBased)
            if let err = prep.error { return (nil, err) }   // alert up / app crashed → abort with guidance
            foregroundNote = prep.note
        }

        let result = dispatchInner(method: method, cmd: cmd)
        // Surface the re-focus note so the model learns the app had drifted.
        if let note = foregroundNote, var data = result.0 {
            data["app_note"] = .string(note)
            return (data, result.1)
        }
        return result
    }

    private func dispatchInner(method: String, cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        switch method {
        case "device_info":
            return deviceInfo()
        case "screenshot":
            return screenshot(cmd)
        case "tap":
            return tap(cmd)
        case "double_tap":
            return doubleTap(cmd)
        case "long_press":
            return longPress(cmd)
        case "swipe":
            return swipe(cmd)
        case "page", "page_down", "page_up":
            return pageScroll(cmd, method: method)
        case "scroll":
            return scroll(cmd)
        case "type":
            return typeText(cmd)
        case "clear_text":
            return clearText(cmd)
        case "home":
            return pressHome()
        case "lock":
            return lock()
        case "unlock":
            return unlock()
        case "is_locked":
            return isLocked()
        case "list_apps", "installed_apps":
            return listApps(cmd)
        case "resolve_app", "search_app", "search_apps":
            return resolveApp(cmd)
        case "open_url", "open":
            return openURL(cmd)
        case "launch_app":
            return launchApp(cmd)
        case "activate_app":
            return activateApp(cmd)
        case "terminate_app":
            return terminateApp(cmd)
        case "page_source", "view_tree", "ui_tree":
            return pageSource(cmd)
        case "scroll_to_element", "scroll_to":
            return scrollToElement(cmd)
        case "find_element":
            return findElementInfo(cmd)
        case "tap_element":
            return tapElement(cmd)
        case "find_and_tap":
            return findAndTap(cmd)
        case "drag":
            return drag(cmd)
        case "wait":
            return wait(cmd)
        default:
            return (nil, .methodNotFound)
        }
    }

    // MARK: - Device

    private func deviceInfo() -> ([String: JSONValue]?, JSONRPCError?) {
        let device = UIDevice.current
        // device_info intentionally reads the live frame once (and caches it),
        // so the reported size is authoritative for the session.
        let frame = pointSize
        let s = scale
        let result: [String: JSONValue] = [
            "device_name": .string(device.name),
            "model": .string(device.model),
            "system_version": .string(device.systemVersion),
            // Server identity + capabilities — a client gets device info AND what
            // this server supports from a single device_info call (no /schema fetch
            // needed for feature detection).
            "server_version": .string(RPCMethodRegistry.serverVersion),
            "protocol_version": .int(RPCMethodRegistry.protocolVersion),
            "capabilities": .array(RPCMethodRegistry.capabilityTags.map { .string($0) }),
            // Coordinate space that tap/swipe/drag/long_press use:
            "point_width": .double(frame.width),
            "point_height": .double(frame.height),
            "scale": .double(s),
            // Pixel dimensions a screenshot will have:
            "pixel_width": .double(frame.width * s),
            "pixel_height": .double(frame.height * s),
            // Kept for backward compatibility:
            "screen_width": .double(frame.width),
            "screen_height": .double(frame.height),
            "screen_scale": .double(s),
            "coordinate_space": .string("points"),
            "hint": .string(
                "All tap/swipe/drag/long_press coordinates are in POINTS, range " +
                "x∈[0,\(Int(frame.width))] y∈[0,\(Int(frame.height))]. " +
                "Screenshots are \(Int(frame.width * s))×\(Int(frame.height * s)) PIXELS. " +
                "To tap a screenshot location: point = pixel / \(s). " +
                "Bottom tab bars sit above the home-indicator safe area (~y \(Int(frame.height) - 60)–\(Int(frame.height) - 20))."
            ),
        ]
        return (result, nil)
    }

    private func screenshot(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // XCUIScreen.screenshot() grabs the current frame directly and does NOT
        // wait for quiescence. Use the CACHED point size (not app.frame) so the
        // screenshot path stays fast on animation-heavy apps.
        let frame = pointSize
        let deviceScale = scale  // native pixels-per-point (e.g. 3)

        // Requested output scale (pixels-per-point): default 2, clamp to (0, 3].
        let requested = cmd.scale ?? 2.0
        let targetScale = min(max(requested, 0.05), 3.0)

        // Target selection:
        //   - explicit bundle_id → screenshot ONLY that app's window (opt-in)
        //   - otherwise → the WHOLE SCREEN (XCUIScreen) — always fast (~0.4s).
        // IMPORTANT: we DO NOT use the sticky boundBundleId here. App-scoped
        // XCUIApplication.screenshot() can block for 8s+ while the app is in a
        // transition (page switch / loading), which blocked the main thread long
        // enough for XCTest to terminate the test (observed crash, twice).
        // XCUIScreen.screenshot() is always fast and captures whatever's on screen,
        // which is what you want by default anyway.
        var fullImage: UIImage
        let scopedTo: String?
        if let bid = cmd.bundleId, !bid.isEmpty {
            // Explicit opt-in: app-scoped, but time-bounded (fall back to the fast
            // full-screen shot if it's slow/throws/black). This is the ONLY path
            // that can be slow, and only when the caller explicitly asked for it.
            var appImage: UIImage?
            var finished = false
            let done = runWithTimeout(seconds: 3) {
                _ = ObjCException.catching {
                    appImage = XCUIApplication(bundleIdentifier: bid).screenshot().image
                }
                finished = true
            }
            if done, finished, let img = appImage {
                fullImage = img
                scopedTo = bid
            } else {
                fullImage = XCUIScreen.main.screenshot().image
                scopedTo = nil
                iCTRLUITests.logBuffer.append("📸 app-scoped screenshot for \(bid) slow/failed — fell back to full screen")
            }
        } else {
            fullImage = XCUIScreen.main.screenshot().image
            scopedTo = nil
        }

        // Resize on the server to targetScale so the client gets a smaller PNG.
        let targetPixelW = frame.width * targetScale
        let targetPixelH = frame.height * targetScale
        let pngData = Self.encodePNG(fullImage, targetPixels: CGSize(width: targetPixelW, height: targetPixelH))
        let base64 = pngData.base64EncodedString()

        let result: [String: JSONValue] = [
            "format": .string("png"),
            "encoding": .string("base64"),
            "data": .string(base64),
            // Pixel dimensions of THIS (possibly downscaled) image:
            "pixel_width": .double(targetPixelW),
            "pixel_height": .double(targetPixelH),
            // The point-space to convert INTO before tapping:
            "point_width": .double(frame.width),
            "point_height": .double(frame.height),
            "scale": .double(targetScale),
            "requested_scale": .double(requested),
            "device_scale": .double(deviceScale),
            "device_name": .string(UIDevice.current.name),
            // Kept for backward compatibility:
            "width": .double(frame.width),
            "height": .double(frame.height),
            "hint": .string(
                "This image is \(Int(targetPixelW))×\(Int(targetPixelH)) PIXELS at scale \(targetScale). " +
                "tap/swipe coordinates are in POINTS (\(Int(frame.width))×\(Int(frame.height))). " +
                "Convert a pixel location (px,py) in THIS image to a tap point with: " +
                "x = px / \(targetScale), y = py / \(targetScale). Prefer page_source to avoid this conversion."
            ),
        ]
        var out = result
        if let bid = scopedTo {
            out["scoped_to"] = .string(bid)
            out["scope"] = .string("app")
        } else {
            out["scope"] = .string("screen")
        }
        return (out, nil)
    }

    /// Render a UIImage to PNG at the requested pixel size (server-side downscale).
    private static func encodePNG(_ image: UIImage, targetPixels: CGSize) -> Data {
        let w = max(1, Int(targetPixels.width.rounded()))
        let h = max(1, Int(targetPixels.height.rounded()))
        let size = CGSize(width: w, height: h)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1               // we specify size in raw pixels
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.pngData() ?? image.pngData() ?? Data()
    }

    // MARK: - Tap

    /// Resolve a ref for a spatial action, returning the live element or a
    /// descriptive error. Shared by tap/double_tap/long_press.
    private func resolveRefForAction(_ refId: String) -> (XCUIElement?, JSONRPCError?) {
        guard let el = resolveRef(refId) else {
            return (nil, JSONRPCError(code: -32602, message: "ref '\(refId)' no longer resolves — element gone, view changed, or ref expired (refs live 1 hour). Re-find it with find_element/scroll_to_element.", data: nil))
        }
        guard el.isHittable else {
            let f = el.frame
            return (nil, JSONRPCError(code: -32602, message: "Element for ref '\(refId)' exists but isn't hittable; scroll it fully into view (scroll_to_element) or tap its center by coordinate (\(Int(f.midX)),\(Int(f.midY))).", data: nil))
        }
        return (el, nil)
    }

    /// A small random offset (±maxJitter pt, default 3) to add to an element-tap
    /// point so successive taps don't all land on the exact same pixel — a little
    /// more human. Clamped so the point stays comfortably inside the element frame
    /// (never within 2pt of an edge), and skipped for tiny elements.
    private func humanizedPoint(in frame: CGRect, maxJitter: Double = 3.0) -> (Double, Double) {
        let cx = Double(frame.midX), cy = Double(frame.midY)
        // Keep at least a 2pt margin from each edge; if the element is too small to
        // jitter safely, just use the center.
        let jx = min(maxJitter, max(0, Double(frame.width) / 2 - 2))
        let jy = min(maxJitter, max(0, Double(frame.height) / 2 - 2))
        func rand(_ mag: Double) -> Double {
            guard mag > 0 else { return 0 }
            // Uniform in [-mag, +mag], 0.1pt resolution.
            let steps = UInt32(mag * 20) + 1              // e.g. mag=3 → 61 steps
            let v = Double(arc4random_uniform(steps)) / 10.0
            return v - mag
        }
        return (cx + rand(jx), cy + rand(jy))
    }

    private func tap(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // Prefer a stable element ref if provided (re-resolves the live element).
        if let refId = cmd.ref {
            let (el, err) = resolveRefForAction(refId)
            if let err = err { return (nil, err) }
            // Resolve the element to its frame and tap by SYNTHESIZED event
            // (fastTap) instead of XCUIElement.tap(). XCUIElement.tap() does its own
            // waiting and post-event settling; when the tap navigates to a new page
            // that settling ran ~4s and coincided with the test being torn down.
            // A coordinate synthesized tap is fast (<1s) and doesn't wait.
            // Land a few pt off-center (within the element) so taps look less robotic.
            let f = el!.frame
            let label = el!.label
            let (cx, cy) = humanizedPoint(in: f)
            let r = fastHandler.fastTap(x: cx, y: cy)
            if r.1 != nil {
                // Fallback to element tap only if the synthesized tap failed.
                el!.tap()
            }
            return (["message": .string("Tapped ref \(refId) ('\(label)') at (\(Int(cx)),\(Int(cy)))")], nil)
        }

        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "tap requires x and y (in points), or a 'ref' from find_element/scroll_to_element", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "tap") { return (nil, err) }

        // Fast (event synthesis) is the DEFAULT — it doesn't wait for UI quiescence,
        // which on animation-heavy apps could block for up to 60s. Pass fast:false
        // only if you specifically need XCUITest's element-aware tap.
        if cmd.fast != false {
            return fastHandler.fastTap(x: x, y: y)
        }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.tap()

        return ([
            "message": .string("Tapped at (\(x), \(y))"),
            "screen": coordinateHint,
        ], nil)
    }

    private func doubleTap(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // ref-first, like tap.
        if let refId = cmd.ref {
            let (el, err) = resolveRefForAction(refId)
            if let err = err { return (nil, err) }
            el!.doubleTap()
            return (["message": .string("Double tapped ref \(refId) ('\(el!.label)')")], nil)
        }
        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "double_tap requires x and y (in points), or a 'ref'", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "double_tap") { return (nil, err) }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.doubleTap()

        return (["message": .string("Double tapped at (\(x), \(y))"), "screen": coordinateHint], nil)
    }

    private func longPress(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let duration = cmd.duration ?? 2.0
        // ref-first, like tap.
        if let refId = cmd.ref {
            let (el, err) = resolveRefForAction(refId)
            if let err = err { return (nil, err) }
            el!.press(forDuration: duration)
            return (["message": .string("Long pressed ref \(refId) ('\(el!.label)') for \(duration)s")], nil)
        }
        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "long_press requires x and y (in points), or a 'ref'", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "long_press") { return (nil, err) }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.press(forDuration: duration)

        return (["message": .string("Long pressed at (\(x), \(y)) for \(duration)s"), "screen": coordinateHint], nil)
    }

    // MARK: - Swipe & Scroll

    /// Page-scroll: move by (about) one screenful, like Page Down / Page Up on a
    /// keyboard. Precise (no momentum) so you can read content page by page without
    /// the overshoot that swipe+velocity:fast causes. Params:
    ///   direction: "down" (default, reveal content below) / "up"; page_down/page_up
    ///     methods force the direction.
    ///   pages: how many screenfuls (default 1; e.g. 0.5 for half a page).
    private func pageScroll(_ cmd: ActionCommand, method: String) -> ([String: JSONValue]?, JSONRPCError?) {
        let size = pointSize
        let cx = size.width / 2

        // Direction: explicit method wins, else the `direction` param, else down.
        var goingDown = true
        if method == "page_up" { goingDown = false }
        else if method == "page_down" { goingDown = true }
        else if let d = cmd.direction?.lowercased() { goingDown = (d != "up") }

        // Number of screenfuls (default 1). One "page" moves ~85% of the height so
        // a sliver of overlap remains for reading continuity.
        let pages = max(0.1, min(cmd.distance ?? 1.0, 5.0))   // reuse `distance` as page count
        let pageTravel = size.height * 0.85 * pages

        // Scroll within the middle band, away from the very top/bottom (nav bars,
        // home indicator, pull-to-refresh zones).
        let fromY: Double, toY: Double
        if goingDown {
            fromY = size.height * 0.78
            toY = max(size.height * 0.12, fromY - pageTravel)
        } else {
            fromY = size.height * 0.22
            toY = min(size.height * 0.88, fromY + pageTravel)
        }

        // Precise drag: a long moveDuration means NO iOS momentum — content moves
        // ~exactly the finger travel, page by page.
        let r = fastHandler.fastSwipe(fromX: cx, fromY: fromY, toX: cx, toY: toY, duration: 0.45)
        if r.1 != nil { return r }
        return ([
            "message": .string("Paged \(goingDown ? "down" : "up") \(pages) screenful(s). Precise scroll (no momentum). Re-read with page_source/screenshot."),
            "screen": coordinateHint,
        ], nil)
    }

    private func swipe(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // x/y are OPTIONAL. Default start point is the screen center, so a bare
        // {"method":"swipe","params":{"direction":"up"}} scrolls from the middle.
        let size = pointSize
        let x = cmd.x ?? size.width / 2
        let y = cmd.y ?? size.height / 2
        if let err = validateCoordinate(x: x, y: y, context: "swipe start") { return (nil, err) }

        let direction = cmd.direction ?? "up"
        // Default finger travel is 100 pt from the start point (per spec).
        let distance = cmd.distance ?? 100.0

        let endX: Double
        let endY: Double
        switch direction {
        case "up":    endX = x; endY = y - distance
        case "down":  endX = x; endY = y + distance
        case "left":  endX = x - distance; endY = y
        case "right": endX = x + distance; endY = y
        default:
            return (nil, JSONRPCError(
                code: -32602,
                message: "Invalid swipe direction '\(direction)'. Use one of: up, down, left, right.",
                data: nil
            ))
        }

        // Clamp endpoint into bounds rather than failing — swipes near edges are common.
        let clampedEndX = min(max(endX, 0), size.width)
        let clampedEndY = min(max(endY, 0), size.height)

        // Velocity controls how the gesture is interpreted:
        //   "fast"/"flick"   → quick swipe, triggers iOS momentum → scrolls FAR beyond finger travel
        //   "normal"         → moderate (default)
        //   "slow"/"precise" → precise drag, moves ~exactly the finger travel, no momentum
        // Shorter move duration = higher velocity = more momentum.
        let velocity = cmd.velocity ?? "normal"
        let moveDuration: Double
        switch velocity.lowercased() {
        case "fast", "flick":   moveDuration = 0.05
        case "slow", "precise": moveDuration = 0.5
        default:                moveDuration = 0.15
        }

        if cmd.fast != false {
            // Default to the synthesized fast path (no quiescence wait); velocity via duration.
            let r = fastHandler.fastSwipe(fromX: x, fromY: y, toX: clampedEndX, toY: clampedEndY, duration: moveDuration)
            if var data = r.0 {
                data["from"] = .object(["x": .double(x), "y": .double(y)])
                data["velocity"] = .string(velocity)
                data["note"] = .string("Started at (\(Int(x)),\(Int(y))) — default is screen center. velocity=\(velocity): 'fast' adds momentum (scrolls farther), 'slow' is a precise drag.")
                return (data, r.1)
            }
            return r
        }

        // Legacy XCUITest path (waits for quiescence).
        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = normalized.withOffset(CGVector(dx: x, dy: y))
        let end = normalized.withOffset(CGVector(dx: clampedEndX, dy: clampedEndY))
        start.press(forDuration: 0.1, thenDragTo: end)

        return ([
            "message": .string("Swiped \(direction) from (\(x), \(y)) to (\(clampedEndX), \(clampedEndY))"),
            "screen": coordinateHint,
        ], nil)
    }

    private func scroll(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let direction = cmd.direction ?? "down"
        switch direction {
        case "up":    app.swipeUp()
        case "down":  app.swipeDown()
        case "left":  app.swipeLeft()
        case "right": app.swipeRight()
        default:
            return (nil, JSONRPCError(
                code: -32602,
                message: "Invalid scroll direction '\(direction)'. Use one of: up, down, left, right. " +
                    "Note: direction is the finger movement — 'up' reveals content below.",
                data: nil
            ))
        }
        return (["message": .string("Scrolled \(direction)")], nil)
    }

    // MARK: - Type

    /// Best-effort detection of an on-screen keyboard. NOTE: this is unreliable —
    /// third-party keyboards (Google/Sogou/…) and many apps render the keyboard in
    /// a process whose elements don't appear in the app's OR SpringBoard's
    /// accessibility tree, so a visible keyboard can still report count == 0.
    /// Because of that we use this only for a SOFT warning, never to block typing.
    private func hasKeyboardFocus() -> Bool {
        let bid = resolveForegroundBundleId()
        let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        if target.keyboards.count > 0 { return true }
        if app.keyboards.count > 0 { return true }
        // SpringBoard hosts the system keyboard on some setups.
        if XCUIApplication(bundleIdentifier: "com.apple.springboard").keyboards.count > 0 { return true }
        return false
    }

    /// Advisory keyboard-focus warning, computed AFTER the text has been
    /// synthesized. Best-effort and cheap: a single keyboards.count probe on the
    /// foreground app (the cross-app SpringBoard probe is skipped — it's the
    /// slowest and this is only for a soft hint, never to block or fail typing).
    private func keyboardWarningAfterType() -> String? {
        let bid = resolveForegroundBundleId()
        let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        if target.keyboards.count > 0 { return nil }
        return "Could not confirm a focused text field / visible keyboard (detection can't see all keyboards). " +
            "If the text didn't appear, tap a real textfield first (find_element{element_type:\"textfield\"} → tap{ref}), wait ~1s, then type again. A home-screen 'search bar' is often a button that opens a separate search page."
    }

    private func typeText(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let clearFirst = cmd.clear == true
        // text is optional when clear:true (type{clear:true} just empties the field).
        guard let text = cmd.text ?? (clearFirst ? "" : nil) else {
            return (nil, JSONRPCError(code: -32602, message: "type requires a 'text' parameter (or clear:true to just empty the field)", data: nil))
        }

        var focusedByTap = false
        if let x = cmd.x, let y = cmd.y {
            if let err = validateCoordinate(x: x, y: y, context: "type focus tap") { return (nil, err) }
            let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
            coordinate.tap()
            usleep(500_000)
            focusedByTap = true
        }

        // clear:true empties the field before typing (tap to focus first, above).
        if clearFirst { clearFocusedField() }

        // submit:true appends a Return/Search keystroke so the field's action
        // (search/go/send) fires — synthesized text alone often doesn't trigger it.
        let submit = cmd.submit == true

        // NOTE: keyboard detection (hasKeyboardFocus) is a SOFT warning only, and
        // its keyboards.count queries wait for quiescence — on a live/animating
        // page (e.g. char-by-char typing) they can block until the 6s RPC watchdog
        // fires, making a SUCCESSFUL type look like a timeout. So we do NOT probe
        // the keyboard before typing. Synthesize first (the actual input), return
        // immediately, and only then do a best-effort keyboard check for the
        // advisory warning — computed AFTER the text is already in.
        if cmd.fast == true {
            let r = fastHandler.fastTypeText(text)
            if submit, r.1 == nil { sendReturnKey() }
            if var data = r.0 {
                let prefix = clearFirst ? "Cleared then typed: " : "Typed: "
                data["message"] = .string(text.isEmpty && clearFirst ? "Cleared focused field" : (prefix + text + (submit ? " + Return" : "")))
                if let w = keyboardWarningAfterType() { data["warning"] = .string(w) }
                return (data, r.1)
            }
            return r
        }

        let eventRecord = XCSynthesizedEventRecord(name: "Type")
        let eventPath = XCPointerEventPath(forTextInput: ())
        eventPath.typeText(text, atOffset: 0.0, typingSpeed: 60, shouldRedact: false)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            if submit { sendReturnKey() }
            let prefix = clearFirst ? "Cleared then typed: " : "Typed: "
            let msg = text.isEmpty && clearFirst ? "Cleared focused field" : (prefix + text + (submit ? " + Return" : ""))
            var out: [String: JSONValue] = ["message": .string(msg)]
            if let w = keyboardWarningAfterType() { out["warning"] = .string(w) }
            return (out, nil)
        } catch {
            let guidance = focusedByTap
                ? "Typing failed even after tapping to focus. The tapped point may not be a text field, or the keyboard did not appear. Take a screenshot to confirm a text field is focused (keyboard visible), then retry."
                : "Typing failed: no input field currently has keyboard focus. First tap the text field (pass x,y to this command, or call tap), wait for the keyboard, then type."
            return (nil, JSONRPCError(code: -32603, message: guidance, data: nil))
        }
    }

    /// Synthesize a Return/Enter keystroke (triggers Search/Go/Send on the field).
    private func sendReturnKey() {
        let record = XCSynthesizedEventRecord(name: "Return")
        let path = XCPointerEventPath(forTextInput: ())
        path.typeText("\n", atOffset: 0.0, typingSpeed: 60, shouldRedact: false)
        record.add(path)
        try? record.synthesize()
    }

    /// Clear the currently-focused text field. Requires the field to already have
    /// keyboard focus (tap it first). Strategy: move the caret to the end, then
    /// send a run of backspaces. We size the run from the focused element's value
    /// length when we can read it, and otherwise fall back to a generous default
    /// (extra backspaces past an empty field are harmless no-ops).
    /// Returns the number of delete keystrokes sent.
    @discardableResult
    private func clearFocusedField() -> Int {
        // Best-effort read of the focused element's current text length.
        var count = 0
        if let bid = resolveForegroundBundleId() {
            let target = XCUIApplication(bundleIdentifier: bid)
            // The focused field usually surfaces as the element with keyboardFocus.
            let focused = target.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            if focused.exists, let v = focused.value as? String { count = v.count }
            if count == 0 {
                let sv = target.secureTextFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
                if sv.exists, let v = sv.value as? String { count = v.count }
            }
        }
        // Fall back to a generous fixed count if we couldn't measure it. Cap the
        // measured count too, so a pathological value can't send thousands of keys.
        let deletes = min(max(count, count == 0 ? 60 : count), 200)

        // Move caret to end first (End of text), then delete backwards. \u{8} is
        // backspace; some fields also honor forward-delete, but backspace after
        // caret-to-end covers the common case.
        let record = XCSynthesizedEventRecord(name: "ClearText")
        let path = XCPointerEventPath(forTextInput: ())
        let backspaces = String(repeating: "\u{8}", count: deletes)
        path.typeText(backspaces, atOffset: 0.0, typingSpeed: 90, shouldRedact: false)
        record.add(path)
        try? record.synthesize()
        return deletes
    }

    /// clear_text method: clear the focused field without typing anything new.
    private func clearText(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let keyboardConfirmed = hasKeyboardFocus()
        let sent = clearFocusedField()
        var out: [String: JSONValue] = [
            "message": .string("Cleared focused field (\(sent) deletes sent)"),
        ]
        if !keyboardConfirmed {
            out["warning"] = .string(
                "Could not confirm a focused text field / visible keyboard. If the field wasn't cleared, " +
                "tap a real textfield first (find_element{element_type:\"textfield\"} → tap{ref}), then clear_text again.")
        }
        return (out, nil)
    }

    // MARK: - Device Buttons

    private func pressHome() -> ([String: JSONValue]?, JSONRPCError?) {
        XCUIDevice.shared.press(.home)
        return (["message": .string("Pressed home")], nil)
    }

    private func lock() -> ([String: JSONValue]?, JSONRPCError?) {
        let monitor = LockStateMonitor.shared()
        do {
            try monitor.lockScreen(withTimeout: 5.0)
            return (["message": .string("Screen locked")], nil)
        } catch {
            return (nil, .serverError("Lock failed: \(error.localizedDescription)"))
        }
    }

    private func unlock() -> ([String: JSONValue]?, JSONRPCError?) {
        let monitor = LockStateMonitor.shared()
        do {
            try monitor.unlockScreen(withTimeout: 5.0)
            return (["message": .string("Screen unlocked")], nil)
        } catch {
            return (nil, .serverError(
                "Unlock failed: \(error.localizedDescription). " +
                "This only wakes the screen; if the device has a passcode, it cannot be entered automatically — " +
                "the user must unlock manually. Call is_locked to check the current state."
            ))
        }
    }

    private func isLocked() -> ([String: JSONValue]?, JSONRPCError?) {
        let locked = LockStateMonitor.shared().isLocked
        return (["locked": .bool(locked)], nil)
    }

    // MARK: - App Control

    /// Run a potentially-blocking app action off the main thread with a watchdog.
    /// XCUIApplication.launch()/activate() can hang indefinitely (bad bundle id,
    /// animation-heavy launch), and since RPCs run serially on the main thread,
    /// one hang freezes the WHOLE server. This bounds the wait and returns instead.
    private func runWithTimeout(seconds: TimeInterval, _ work: @escaping () -> Void) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            sem.signal()
        }
        return sem.wait(timeout: .now() + seconds) == .success
    }

    /// List installed apps (bundle_id + name). Optional `text` filters by a
    /// case-insensitive substring of the name or bundle id. `element_type`=="all"
    /// includes system apps (default: user apps only).
    private func listApps(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let userOnly = (cmd.elementType?.lowercased() != "all")
        guard let apps = ForegroundApp.installedAppsUserOnly(userOnly) else {
            return (nil, .serverError("Could not list installed apps (LSApplicationWorkspace unavailable)."))
        }

        let filter = cmd.text?.lowercased()
        var items: [JSONValue] = []
        for entry in apps {
            let bid = entry["bundle_id"] as? String ?? ""
            let name = entry["name"] as? String ?? ""
            if let f = filter, !f.isEmpty,
               !name.lowercased().contains(f), !bid.lowercased().contains(f) {
                continue
            }
            items.append(.object([
                "bundle_id": .string(bid),
                "name": .string(name),
            ]))
        }

        return ([
            "count": .int(items.count),
            "apps": .array(items),
            "hint": .string("Use a bundle_id with launch_app. Pass {\"text\":\"大麦\"} to filter, or {\"element_type\":\"all\"} to include system apps."),
        ], nil)
    }

    /// Built-in app catalog (name → bundle_id), loaded once from AppBundles.plist
    /// bundled into the runner. Lets resolve_app answer common apps instantly and
    /// offline; misses fall back to the iTunes Search API.
    private static let builtInApps: [[String: String]] = {
        // The plist ships inside the .xctest bundle.
        let bundle = Bundle(for: ActionHandler.self)
        guard let url = bundle.url(forResource: "AppBundles", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let apps = obj["apps"] as? [[String: String]] else {
            return []
        }
        return apps
    }()

    /// Case-insensitive lookup in the built-in catalog by name / query / bundle_id.
    /// Returns matches as {name, bundle_id} dicts.
    private func lookupBuiltInApps(_ term: String) -> [[String: String]] {
        let t = term.lowercased()
        return Self.builtInApps.filter { app in
            (app["name"]?.lowercased().contains(t) ?? false) ||
            (app["query"]?.lowercased().contains(t) ?? false) ||
            (app["bundle_id"]?.lowercased().contains(t) ?? false)
        }
    }

    /// Resolve an app name/keyword to its bundle_id (+ basic info). Checks the
    /// built-in catalog first (offline/instant), then the iTunes Search API.
    /// Use this to get the bundle_id for launch_app when you only know the app's
    /// name. Params: text (query, required), country (default cn), limit (default 5).
    private func resolveApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let term = cmd.text, !term.isEmpty else {
            return (nil, JSONRPCError(code: -32602, message: "resolve_app requires 'text' (the app name / keyword to resolve to a bundle_id)", data: nil))
        }
        let country = cmd.country ?? "cn"
        let limit = min(max(Int(cmd.distance ?? 5), 1), 25)

        // 1) Built-in catalog first — instant, offline, covers common apps.
        let builtIn = lookupBuiltInApps(term)
        if !builtIn.isEmpty {
            let apps: [JSONValue] = builtIn.prefix(limit).map { a in
                .object([
                    "name": .string(a["name"] ?? ""),
                    "bundle_id": .string(a["bundle_id"] ?? ""),
                    "source": .string("built-in"),
                ])
            }
            return ([
                "count": .int(apps.count),
                "term": .string(term),
                "source": .string("built-in"),
                "apps": .array(apps),
                "hint": .string("Matched the built-in app catalog (instant, offline). Use a bundle_id with launch_app. For apps not in the catalog, search still falls through to the App Store."),
            ], nil)
        }

        // 2) Fall back to the iTunes Search API.
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        guard let url = comps.url else {
            return (nil, JSONRPCError(code: -32602, message: "Invalid search term", data: nil))
        }

        // Synchronous fetch with a bounded wait (this runs on the main thread).
        var payload: Data?
        var netError: Error?
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, _, err in
            payload = data; netError = err; sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 10) != .success {
            task.cancel()
            return (nil, .serverError("App Store search timed out (network). Check the device's internet connection."))
        }
        if let netError = netError {
            return (nil, .serverError("App Store search failed: \(netError.localizedDescription)"))
        }
        guard let data = payload,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            return (nil, .serverError("App Store search returned no parseable results."))
        }

        let apps: [JSONValue] = results.map { r in
            .object([
                "name": .string(r["trackName"] as? String ?? ""),
                "bundle_id": .string(r["bundleId"] as? String ?? ""),
                "developer": .string(r["artistName"] as? String ?? ""),
                "category": .string(r["primaryGenreName"] as? String ?? ""),
                "rating": .double((r["averageUserRating"] as? Double) ?? 0),
                "rating_count": .int((r["userRatingCount"] as? Int) ?? 0),
                "price": .string(r["formattedPrice"] as? String ?? ""),
                "version": .string(r["version"] as? String ?? ""),
                "track_id": .int((r["trackId"] as? Int) ?? 0),
            ])
        }

        return ([
            "count": .int(apps.count),
            "term": .string(term),
            "country": .string(country),
            "source": .string("app_store"),
            "apps": .array(apps),
            "hint": .string("Resolved via the App Store (iTunes Search). Use a result's bundle_id with launch_app. Note: the bundle_id confirms App Store identity but does NOT mean the app is installed on THIS device — launch_app will tell you if it isn't."),
        ], nil)
    }

    /// Open any URL from the runner (custom scheme or https://) to jump to an app
    /// or a deep-linked feature — e.g. "weixin://", "alipays://platformapi/…",
    /// "https://…", "tel:…", or a callback like "minis://done?x=1". Uses the same
    /// XCTest-daemon path that reliably opens URLs from inside the runner.
    private func openURL(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let raw = cmd.url ?? cmd.text, !raw.isEmpty else {
            return (nil, JSONRPCError(code: -32602, message: "open_url requires a 'url' (e.g. 'weixin://', 'https://example.com', 'alipays://platformapi/startapp?...')", data: nil))
        }
        guard let url = URL(string: raw) else {
            return (nil, JSONRPCError(code: -32602, message: "'\(raw)' is not a valid URL. URL-encode query values if needed.", data: nil))
        }
        let opened = ForegroundApp.open(url)
        guard opened else {
            return (nil, .serverError(
                "Could not open '\(raw)'. The scheme may not be installed/registered, or the URL is malformed. " +
                "For opening an app by identity, use launch_app with a bundle_id instead."
            ))
        }
        // If the URL scheme maps to a known app coming to the foreground, the sticky
        // target will be re-detected on the next action; we don't force-bind here
        // because a URL can also just trigger an in-app action.
        usleep(500_000)
        return ([
            "message": .string("Opened URL \(url.scheme ?? "")://… . Give it a moment, then page_source/screenshot to see where it landed."),
        ], nil)
    }

    private func launchApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId else {
            return (nil, JSONRPCError(code: -32602, message: "launch_app requires a 'bundle_id' (e.g. 'com.apple.Preferences', 'ctrip.com')", data: nil))
        }
        // Open via LSApplicationWorkspace (same as WebDriverAgent): this is
        // NON-BLOCKING and returns immediately — no quiescence wait, so a wrong
        // bundle_id or an ad/launch screen can't hang the whole server (which is
        // what XCUIApplication.launch()/activate() did).
        let opened = ForegroundApp.openBundleID(bundleId)
        guard opened else {
            return (nil, .serverError(
                "Could not open '\(bundleId)'. The bundle_id is likely wrong or not installed. Call list_apps to find the correct one."
            ))
        }
        usleep(800_000)  // brief settle; app is coming to foreground async
        lastForegroundBundleId = bundleId
        boundBundleId = bundleId       // sticky target for subsequent actions
        lastBoundActivateAt = nowMonotonic  // just brought forward — skip redundant re-activate
        return ([
            "message": .string("Opened \(bundleId). Actions now target this app until you open another. IMPORTANT: the app is still launching/rendering — wait 2-3s (call wait), THEN page_source to confirm the UI is stable before locating elements. Acting too early matches placeholder/splash elements or is very slow (cold-start element queries can take 6s+)."),
            "bound_app": .string(bundleId),
            "advice": .string("wait 2-3s, then page_source"),
        ], nil)
    }

    private func activateApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId else {
            return (nil, JSONRPCError(code: -32602, message: "activate_app requires a 'bundle_id'", data: nil))
        }
        // Safe activate (Obj-C @try/@catch) — a raw XCUIApplication.activate() can
        // throw an NSException that Swift can't catch and that aborts the runner.
        var activated = false
        let ok = runWithTimeout(seconds: 5) {
            activated = ForegroundApp.safeActivateBundleID(bundleId)
        }
        guard ok else {
            return (nil, .serverError("activate_app timed out after 5s for '\(bundleId)'. Check the bundle_id."))
        }
        guard activated else {
            return (nil, .serverError("Could not activate '\(bundleId)' (not installed, or activation failed). Use resolve_app/list_apps to verify the bundle_id."))
        }
        lastForegroundBundleId = bundleId
        boundBundleId = bundleId       // sticky target for subsequent actions
        lastBoundActivateAt = nowMonotonic  // just brought forward — skip redundant re-activate
        return (["message": .string("Activated \(bundleId). Actions now target this app.")], nil)
    }

    private func terminateApp(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId else {
            return (nil, JSONRPCError(code: -32602, message: "terminate_app requires a 'bundle_id'", data: nil))
        }
        let ok = runWithTimeout(seconds: 5) {
            _ = ForegroundApp.safeTerminateBundleID(bundleId)
        }
        guard ok else {
            return (nil, .serverError("terminate_app timed out after 5s for '\(bundleId)'."))
        }
        // If we just killed the sticky target, unbind so actions fall back to the
        // live foreground app instead of a dead one.
        if boundBundleId == bundleId { boundBundleId = nil }
        return (["message": .string("Terminated \(bundleId)")], nil)
    }

    // MARK: - View Hierarchy

    /// Returns the accessibility/view hierarchy as text — the PREFERRED way for a
    /// model to understand layout (element types, labels, identifiers, frames)
    /// without decoding a screenshot image. Pass bundle_id to inspect a specific
    /// foreground app; otherwise the whole screen (SpringBoard) tree is returned.
    private func pageSource(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // Resolve which app to inspect:
        //   explicit bundle_id → that app
        //   otherwise → detected foreground app (private API, then last-launched)
        let inspectedBundleId = cmd.bundleId ?? resolveForegroundBundleId()

        let target: XCUIApplication
        if let bundleId = inspectedBundleId {
            target = XCUIApplication(bundleIdentifier: bundleId)
        } else {
            // Last resort: SpringBoard (only system UI — warn the caller).
            target = app
        }

        // Pre-check the target's state before snapshotting. snapshot() on an app
        // that isn't frontmost has no main window to read, so the accessibility
        // server returns kAXErrorServerNotFound — but only after XCTest's internal
        // ~16s timeout, blocking the whole call (the RPC 6s watchdog can't cancel
        // the in-flight XCUITest call). A backgrounded bound app is the common
        // cause (e.g. a tap sent the app to the background). Fail fast with a clear
        // recoverable error instead. SpringBoard is always readable, so skip it.
        if let bid = inspectedBundleId, bid != "com.apple.springboard" {
            let state = AppState(rawValue: ForegroundApp.appState(forBundleID: bid)) ?? .unknown
            switch state {
            case .notRunning:
                return (nil, JSONRPCError(code: -32004, message:
                    "Can't read the view tree: app '\(bid)' is not running (it may have crashed or been closed). " +
                    "Call launch_app to (re)open it, then retry.", data: nil))
            case .background, .backgroundSuspended:
                return (nil, JSONRPCError(code: -32004, message:
                    "Can't read the view tree: app '\(bid)' is in the background, so it has no snapshottable window. " +
                    "Bring it to the front first — run one interaction (tap/swipe re-focuses the bound app) or call " +
                    "launch_app/activate_app, then retry page_source.", data: nil))
            default:
                break  // foreground or unknown → proceed (unknown may still work)
            }
        }

        // Custom snapshot traversal so we can bound depth / count and filter —
        // debugDescription enumerates & serializes the WHOLE tree (68KB+ on rich
        // pages), which is what makes the first call block for tens of seconds.
        let maxDepth = cmd.maxDepth ?? Int.max
        // Hard cap to prevent timeouts even when the caller passes nothing.
        let maxElements = min(cmd.maxElements ?? 500, 2000)
        let filter = SnapshotFilter(type: cmd.filterType, label: cmd.filterLabel, text: cmd.filterText)

        // Snapshot roots to render. We take the single application.snapshot()
        // (fast, ~0.5-1s, already contains the main window hierarchy) AND any
        // additional VISIBLE overlay windows — so fixed floating bars (e.g. a
        // buy/submit bar in a separate window) are always included. No opt-in flag
        // is needed because we don't blindly walk every window: the earlier 17s
        // hang came from snapshotting all ~8 windows including offscreen/zero-size
        // ones. Here we frame-check first and only snapshot the 1-2 windows the
        // user can actually see, under a hard 3s budget.
        var roots: [XCUIElementSnapshot] = []
        let appSnap = try? target.snapshot()
        if let appSnap = appSnap { roots.append(appSnap) }

        let screen = pointSize
        // With the 2s XCTest state-timeout cap, target.snapshot() above is bounded;
        // keep the overlay budget tight too so total page_source stays well under
        // the 6s RPC watchdog even on a busy/animating page.
        let budgetDeadline = nowMonotonic + 2.0
        let windowCount = min(target.windows.count, 6)
        for i in 0..<windowCount {
            if nowMonotonic >= budgetDeadline { break }
            let win = target.windows.element(boundBy: i)
            // Cheap frame check first — skip offscreen / zero-size / inactive
            // windows so we only pay snapshot cost for windows the user can see.
            let f = win.frame
            let onScreen = f.width > 1 && f.height > 1
                && f.minX < screen.width && f.minY < screen.height
                && f.maxX > 0 && f.maxY > 0
            guard onScreen else { continue }
            // Skip a window that's the same size as the app root (already covered).
            if let appSnap = appSnap,
               Int(f.width) == Int(appSnap.frame.width),
               Int(f.height) == Int(appSnap.frame.height),
               Int(f.minY) == Int(appSnap.frame.minY) {
                continue
            }
            if let ws = try? win.snapshot() { roots.append(ws) }
        }
        guard !roots.isEmpty else {
            return (nil, .serverError(
                "Could not snapshot the accessibility tree. The app may still be launching — wait briefly and retry, or take a screenshot."
            ))
        }

        var lines: [String] = []
        var count = 0
        var localCount = 0
        var truncated = false
        // Track element frames already emitted so overlapping window/app snapshots
        // don't duplicate the same nodes.
        var seenFrames = Set<String>()
        for root in roots {
            renderSnapshotInto(root, depth: 0, maxDepth: maxDepth, maxElements: maxElements,
                               filter: filter, lines: &lines, localCount: &localCount,
                               globalCount: &count, truncated: &truncated, seenFrames: &seenFrames)
            if count >= maxElements { break }
        }

        let body = lines.joined(separator: "\n")

        var hint = "Accessibility tree (types, labels, identifiers, frames in POINTS), including visible overlay " +
            "windows (fixed bottom/floating bars). Frames are {{x,y},{w,h}} — tap an element at its frame center " +
            "(or use find_element to get a ref). If an element is still missing, the app may not expose it — fall " +
            "back to screenshot + coordinate tap."
        if truncated {
            hint = "⚠️ Tree truncated at \(count) nodes (page has more). Narrow the query: " +
                "pass filter:{label:\"…\"} or filter:{type:\"button\"} to return only matching nodes (with their ancestor path), " +
                "or max_depth:3-4 for just the top structure. " + hint
        } else if filter.active {
            hint = "Filtered view: only nodes matching your filter (plus their ancestors) are shown. " +
                "Remove the filter for the full tree. " + hint
        }

        var result: [String: JSONValue] = [
            "format": .string("text"),
            "source": .string(body),
            "truncated": .bool(truncated),
            "total_returned": .int(count),
            "coordinate_space": .string("points"),
            "hint": .string(hint),
        ]
        if filter.active { result["filtered"] = .bool(true) }
        if let bid = inspectedBundleId {
            result["bundle_id"] = .string(bid)
        } else {
            result["bundle_id"] = .string("com.apple.springboard")
            result["warning"] = .string(
                "Could not determine the foreground app, so this is the SpringBoard (system) tree, " +
                "which does NOT contain the current app's internal elements. " +
                "Pass bundle_id explicitly to inspect a specific app."
            )
        }
        return (result, nil)
    }

    // MARK: - Snapshot rendering (depth/count-bounded, filterable)

    private struct SnapshotFilter {
        let type: String?       // element type name substring (e.g. "button")
        let label: String?      // label/value substring
        let text: String?       // label+value+identifier substring
        var active: Bool { type != nil || label != nil || text != nil }

        /// Does this node itself match all provided filter conditions?
        func matches(_ s: XCUIElementSnapshot) -> Bool {
            if let t = type, !ActionHandler.elementTypeName(s.elementType).lowercased().contains(t.lowercased()) {
                return false
            }
            let label = s.label
            let value = (s.value as? String) ?? ""
            let ident = s.identifier
            if let l = self.label {
                let hay = (label + " " + value).lowercased()
                if !hay.contains(l.lowercased()) { return false }
            }
            if let tx = self.text {
                let hay = (label + " " + value + " " + ident).lowercased()
                if !hay.contains(tx.lowercased()) { return false }
            }
            return true
        }
    }

    /// Recursively render a snapshot subtree into `lines`. When a filter is
    /// active, a node is emitted only if it matches OR one of its descendants
    /// matches — so the ancestor path to every match is preserved and the tree
    /// stays readable. `globalCount` is shared across the whole traversal so the
    /// max_elements hard cap is honored regardless of subtree.
    @discardableResult
    private func renderSnapshotInto(_ s: XCUIElementSnapshot, depth: Int, maxDepth: Int,
                                    maxElements: Int, filter: SnapshotFilter,
                                    lines: inout [String], localCount: inout Int,
                                    globalCount: inout Int, truncated: inout Bool,
                                    seenFrames: inout Set<String>) -> Bool {
        if globalCount >= maxElements { truncated = true; return false }

        // Dedup across app + per-window snapshots: skip a node we've already
        // emitted (same type + frame). Container 'Other'/'Application' roots are
        // allowed to repeat (their frames overlap by nature) but leaf identity is
        // keyed on type+frame+label.
        let f = s.frame
        let key = "\(s.elementType.rawValue)|\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))|\(s.label)"
        let isDup = seenFrames.contains(key)

        let selfMatches = !filter.active || filter.matches(s)
        var childLines: [String] = []
        var descendantMatched = false

        if depth < maxDepth {
            for child in s.children {
                if globalCount >= maxElements { truncated = true; break }
                var sub: [String] = []
                var subCount = 0
                let kept = renderSnapshotInto(child, depth: depth + 1, maxDepth: maxDepth,
                                              maxElements: maxElements, filter: filter,
                                              lines: &sub, localCount: &subCount,
                                              globalCount: &globalCount, truncated: &truncated,
                                              seenFrames: &seenFrames)
                if kept { childLines.append(contentsOf: sub); descendantMatched = true }
            }
        }

        // Skip emitting a duplicate leaf, but still surface children that are new.
        let keep = (!filter.active || selfMatches || descendantMatched) && (!isDup || descendantMatched)
        guard keep else { return false }

        if !isDup {
            seenFrames.insert(key)
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + describeSnapshot(s))
            localCount += 1
            globalCount += 1
        }
        // Append the rendered child subtree AFTER this node — without this the
        // whole descendant tree was silently dropped (only the root was emitted).
        lines.append(contentsOf: childLines)
        return true
    }

    /// One-line description of a snapshot node: Type, label/value/id, frame.
    private func describeSnapshot(_ s: XCUIElementSnapshot) -> String {
        var parts = [Self.elementTypeName(s.elementType)]
        if !s.label.isEmpty { parts.append("label: '\(s.label)'") }
        if let v = s.value as? String, !v.isEmpty { parts.append("value: '\(v)'") }
        if !s.identifier.isEmpty { parts.append("id: '\(s.identifier)'") }
        let f = s.frame
        parts.append("{{\(Int(f.minX)), \(Int(f.minY))}, {\(Int(f.width)), \(Int(f.height))}}")
        return parts.joined(separator: ", ")
    }

    /// Human-readable name for an XCUIElement.ElementType raw value.
    private static func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .any: return "Any"
        case .application: return "Application"
        case .window: return "Window"
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .searchField: return "SearchField"
        case .image: return "Image"
        case .icon: return "Icon"
        case .cell: return "Cell"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .scrollView: return "ScrollView"
        case .switch: return "Switch"
        case .slider: return "Slider"
        case .link: return "Link"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .keyboard: return "Keyboard"
        case .key: return "Key"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .segmentedControl: return "SegmentedControl"
        case .map: return "Map"
        case .webView: return "WebView"
        case .other: return "Other"
        case .group: return "Group"
        default: return "Type\(type.rawValue)"
        }
    }

    /// Scroll until an element whose label/value/identifier contains `element_id`
    /// (or matches accessibility id) becomes visible, then return its tap point.
    /// Uses native XCUIElement scrolling against the foreground app.
    private func scrollToElement(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let query = cmd.elementId, !query.isEmpty else {
            return (nil, JSONRPCError(code: -32602, message: "scroll_to_element requires 'element_id' (label, value, or accessibility id to find)", data: nil))
        }

        let bundleId = cmd.bundleId ?? resolveForegroundBundleId()

        let direction = (cmd.direction ?? "up").lowercased()
        // Smaller step (40% of the screen) so we don't scroll PAST a short target
        // between checks. More attempts to compensate for the shorter travel.
        let maxSwipes = Int(cmd.distance ?? 12)
        // Match mode: "exact" (default, precise) or "contains" (loose).
        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        let typeFilter = cmd.elementType
        let size = pointSize
        let cx = size.width / 2, cy = size.height / 2
        let step = (direction == "left" || direction == "right" ? size.width : size.height) * 0.4

        // Reuse the shared matcher (exact label → id → contains, first hittable).
        func buildMatch() -> (XCUIElement, ElementRef.Match, Int)? {
            return locateElement(query: query, type: typeFilter, bundleId: bundleId, matchMode: matchMode)
        }

        // Lightweight signature of what's on screen, to detect "reached the end"
        // (content stopped moving) and stop early instead of swiping in place.
        func screenSignature() -> String {
            let bid = bundleId ?? resolveForegroundBundleId()
            let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
            // First+last visible static-text labels + count is enough to tell motion.
            let texts = target.staticTexts
            let n = min(texts.count, 40)
            guard n > 0 else { return "empty" }
            var parts: [String] = ["n=\(texts.count)"]
            parts.append(texts.element(boundBy: 0).label)
            parts.append(texts.element(boundBy: n - 1).label)
            return parts.joined(separator: "|")
        }

        func result(_ el: XCUIElement, match: ElementRef.Match, index: Int, swipes: Int) -> ([String: JSONValue]?, JSONRPCError?) {
            let f = el.frame
            let ref = makeRef(ElementRef(bundleId: bundleId, match: match, elementType: typeFilter, index: index, createdAt: nowMonotonic))
            return ([
                "found": .bool(true),
                "swipes": .int(swipes),
                "ref": .string(ref),
                "x": .double(f.midX),
                "y": .double(f.midY),
                "center_x": .double(f.midX),
                "center_y": .double(f.midY),
                "label": .string(el.label),
                "hint": .string("Element is on screen. Prefer tapping by ref: {\"method\":\"tap\",\"params\":{\"ref\":\"\(ref)\"}} — a ref re-resolves the live element and won't drift like a coordinate."),
            ], nil)
        }

        if let (el, m, idx) = buildMatch() { return result(el, match: m, index: idx, swipes: 0) }

        var lastSig = screenSignature()
        var actualSwipes = 0
        var reachedEnd = false

        for i in 1...max(1, maxSwipes) {
            let (ex, ey): (Double, Double)
            switch direction {
            case "down":  (ex, ey) = (cx, cy + step)
            case "left":  (ex, ey) = (cx - step, cy)
            case "right": (ex, ey) = (cx + step, cy)
            default:      (ex, ey) = (cx, cy - step)
            }
            _ = fastHandler.fastSwipe(fromX: cx, fromY: cy,
                                      toX: min(max(ex, 0), size.width),
                                      toY: min(max(ey, 0), size.height), duration: 0.15)
            usleep(300_000)
            actualSwipes = i

            if let (el, m, idx) = buildMatch() { return result(el, match: m, index: idx, swipes: i) }

            // Stop early if the screen didn't change — we've hit the end/edge.
            let sig = screenSignature()
            if sig == lastSig {
                reachedEnd = true
                break
            }
            lastSig = sig
        }

        return (nil, JSONRPCError(
            code: -32602,
            message: "No \(matchMode == "contains" ? "" : "exact ")match for '\(query)'" +
                (typeFilter.map { " of type '\($0)'" } ?? "") +
                " after \(actualSwipes) swipes \(direction)" +
                (reachedEnd ? " (reached the end of scrollable content)" : "") +
                ". Tips: the label may contain hidden/formatting characters — copy it exactly from page_source, or use match:'contains'. Also try the opposite direction, or add element_type.",
            data: nil
        ))
    }

    // MARK: - Elements

    /// Locate an element (without scrolling) in the foreground app by exact label,
    /// then accessibility id, then (if match=contains) substring. Returns the first
    /// hittable match + its index, so both find_element and tap-by-ref agree.
    private func locateElement(query: String, type: String?, bundleId: String?, matchMode: String)
        -> (XCUIElement, ElementRef.Match, Int)? {
        let bid = bundleId ?? resolveForegroundBundleId()
        let target: XCUIApplication = bid.map { XCUIApplication(bundleIdentifier: $0) } ?? app
        let q = elementQuery(in: target, type: type)

        // Phased timing: log how long each match stage takes so slow lookups can be
        // attributed (which stage, and snapshot node count for the fallback).
        let t0 = nowMonotonic
        var phases: [String] = []
        func lap(_ name: String, from: TimeInterval) {
            phases.append("\(name)=\(Int((nowMonotonic - from) * 1000))ms")
        }
        func done(_ hit: String) {
            iCTRLUITests.logBuffer.append("🔎 locate '\(query)' \(hit) [\(phases.joined(separator: " "))] total=\(Int((nowMonotonic - t0) * 1000))ms")
        }

        func firstHittable(_ query: XCUIElementQuery) -> (XCUIElement, Int)? {
            // Avoid query.count (it waits for idle and is expensive). Probe element
            // 0 first; if nothing matches, return fast. Only scan a few when a match
            // exists. isHittable implies exists, so we skip the extra .exists query.
            let first = query.element(boundBy: 0)
            guard first.exists else { return nil }
            if first.isHittable { return (first, 0) }
            for i in 1..<10 {
                let el = query.element(boundBy: i)
                if !el.exists { break }
                if el.isHittable { return (el, i) }
            }
            return (first, 0)   // exists but not hittable — caller decides
        }

        var s = nowMonotonic
        if let (el, idx) = firstHittable(q.matching(NSPredicate(format: "label == %@", query))) {
            lap("exact", from: s)
            let (best, bestIdx) = elevateToButton(match: el, matchIdx: idx, in: target, phases: &phases)
            done("→exact\(bestIdx == idx ? "" : "→button")")
            return (best, .exactLabel(query), bestIdx)
        }
        lap("exact", from: s)

        s = nowMonotonic
        if let (el, idx) = firstHittable(q.matching(identifier: query)) {
            lap("id", from: s)
            let (best, bestIdx) = elevateToButton(match: el, matchIdx: idx, in: target, phases: &phases)
            done("→id\(bestIdx == idx ? "" : "→button")")
            return (best, .identifier(query), bestIdx)
        }
        lap("id", from: s)

        if matchMode == "contains" {
            s = nowMonotonic
            if let (el, idx) = firstHittable(q.matching(NSPredicate(format: "label CONTAINS[c] %@", query))) {
                lap("contains", from: s)
                let (best, bestIdx) = elevateToButton(match: el, matchIdx: idx, in: target, phases: &phases)
                done("→contains\(bestIdx == idx ? "" : "→button")")
                return (best, .containsLabel(query), bestIdx)
            }
            lap("contains", from: s)
        }

        // Fallback: some labels carry invisible bidi/format chars (e.g. U+2066/2068
        // directional isolates around CJK), so a strict "label == query" misses.
        // Instead of querying each element's .label individually (N accessibility
        // round-trips), take ONE snapshot of the tree and walk it IN MEMORY (like
        // WebDriverAgent), then re-resolve only the single winning element to an
        // XCUIElement. This turns ~30-90 queries into 1 snapshot + 1 resolve.
        let wantExact = Self.normalizeLabel(query)
        s = nowMonotonic
        guard let root = try? target.snapshot() else {
            lap("snapshot", from: s); done("✗no-snapshot")
            return nil
        }
        lap("snapshot", from: s)

        // Depth-first walk collecting the first exact-normalized match and, for
        // contains mode, the first substring match. We match on label OR value.
        s = nowMonotonic
        var exactSnap: XCUIElementSnapshot?
        var containsSnap: XCUIElementSnapshot?
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 4000 {
            visited += 1
            let hay = Self.normalizeLabel(node.label + " " + ((node.value as? String) ?? ""))
            if exactSnap == nil, Self.normalizeLabel(node.label) == wantExact {
                exactSnap = node
                break   // exact wins immediately
            }
            if matchMode == "contains", containsSnap == nil,
               hay.localizedCaseInsensitiveContains(wantExact) {
                containsSnap = node
            }
            stack.append(contentsOf: node.children)
        }
        phases.append("walk=\(Int((nowMonotonic - s) * 1000))ms/\(visited)nodes")

        // Re-resolve the matched snapshot to a live XCUIElement by its label (the
        // query layer re-finds it; index 0 of the type-filtered label query).
        s = nowMonotonic
        if let m = exactSnap {
            let re = q.matching(NSPredicate(format: "label == %@", m.label)).element(boundBy: 0)
            if re.exists { lap("resolve", from: s); done("→snapshot-exact"); return (re, .exactLabel(m.label), 0) }
        }
        if let m = containsSnap {
            let re = q.matching(NSPredicate(format: "label == %@", m.label)).element(boundBy: 0)
            if re.exists { lap("resolve", from: s); done("→snapshot-contains"); return (re, .exactLabel(m.label), 0) }
        }
        lap("resolve", from: s)
        done("✗not-found")
        return nil
    }

    /// When a label/identifier match landed on a non-interactive element
    /// (staticText, image, other), SwiftUI content often wraps it in a
    /// Button ancestor whose frame contains the leaf's frame. XCUIElement.tap
    /// on the leaf hits its pixel position but doesn't fire the Button's
    /// handler — same failure mode we've been chasing. Search the app's
    /// Button elements for the TIGHTEST-fitting ancestor (smallest frame
    /// area that still contains the match's centre point). If we find one
    /// AND it's not the match itself, prefer it.
    ///
    /// This is best-effort: if there are no covering buttons, or the match
    /// IS a button, return the input unchanged.
    private func elevateToButton(match: XCUIElement, matchIdx: Int,
                                 in target: XCUIApplication,
                                 phases: inout [String]) -> (XCUIElement, Int) {
        let t0 = nowMonotonic
        // Skip elevation when the match itself is intrinsically tappable —
        // buttons, cells, switches, keys, and menu items already dispatch
        // their own handlers on tap.
        let matchType = match.elementType
        switch matchType {
        case .button, .cell, .switch, .toggle, .radioButton, .checkBox,
             .menuButton, .menuItem, .key, .link, .searchField, .textField, .textView:
            phases.append("elevate=skip(\(matchType.rawValue))")
            return (match, matchIdx)
        default: break
        }
        let matchFrame = match.frame
        // Empty-frame elements can't be usefully compared for containment.
        if matchFrame.width < 1 || matchFrame.height < 1 { return (match, matchIdx) }
        let centre = CGPoint(x: matchFrame.midX, y: matchFrame.midY)

        // Query all buttons; snapshot each frame in one pass. This is cheap
        // for typical screens (<100 buttons) and avoids repeated round-trips.
        let buttons = target.buttons.allElementsBoundByAccessibilityElement
        var best: (XCUIElement, CGRect)?
        for b in buttons {
            let f = b.frame
            if f.width < 1 || f.height < 1 { continue }
            if !f.contains(centre) { continue }
            // Prefer the tightest fit: smallest area that still contains the match.
            let area = f.width * f.height
            if let (_, current) = best, area >= current.width * current.height { continue }
            best = (b, f)
        }
        phases.append("elevate=\(Int((nowMonotonic - t0) * 1000))ms/\(buttons.count)btns")
        if let (btn, _) = best, btn.isHittable {
            return (btn, matchIdx)
        }
        return (match, matchIdx)
    }

    /// Strip invisible formatting/bidi control characters so labels compare cleanly.
    private static func normalizeLabel(_ s: String) -> String {
        let stripped = s.unicodeScalars.filter { scalar in
            // Drop format chars (Cf) like U+2066–2069 (bidi isolates), U+200E/F, etc.
            if scalar.properties.generalCategory == .format { return false }
            return true
        }
        return String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespaces)
    }

    private func findElementInfo(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let elementId = cmd.elementId else {
            return (nil, JSONRPCError(code: -32602, message: "find_element requires 'element_id' (accessibility label or identifier)", data: nil))
        }

        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        guard let (element, match, index) = locateElement(query: elementId, type: cmd.elementType,
                                                          bundleId: cmd.bundleId, matchMode: matchMode) else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "No element matching label/id '\(elementId)'" +
                    (cmd.elementType.map { " of type '\($0)'" } ?? "") +
                    ". It may be off-screen (use scroll_to_element), or the label differs from on-screen text — check page_source. Try match:'contains'.",
                data: nil
            ))
        }

        let frame = element.frame
        let ref = makeRef(ElementRef(bundleId: cmd.bundleId ?? resolveForegroundBundleId(),
                                     match: match, elementType: cmd.elementType, index: index,
                                     createdAt: nowMonotonic))
        // Surface the actual element type so the caller can tell a real text field
        // from a button that merely looks like a search bar. Many app home screens
        // show a search "bar" that is actually a Button/StaticText — tapping it
        // navigates to a search page where the REAL TextField lives.
        let typeName = Self.elementTypeName(element.elementType)
        let isTextInput = element.elementType == .textField
            || element.elementType == .searchField
            || element.elementType == .secureTextField
        var result: [String: JSONValue] = [
            "exists": .bool(true),
            "hittable": .bool(element.isHittable),
            "ref": .string(ref),
            "element_type": .string(typeName),
            "is_text_input": .bool(isTextInput),
            "x": .double(frame.origin.x),
            "y": .double(frame.origin.y),
            "width": .double(frame.width),
            "height": .double(frame.height),
            "center_x": .double(frame.midX),
            "center_y": .double(frame.midY),
            "label": .string(element.label),
            "value": .string(element.value as? String ?? ""),
        ]
        // Nudge the caller when they were probably looking for an input field but
        // matched a button (the classic "fake search bar" trap).
        if !isTextInput, (element.elementType == .button || element.elementType == .staticText || element.elementType == .other) {
            result["note"] = .string(
                "This is a \(typeName), NOT a text field. If you're trying to type/search: tap it to open the search page, wait ~1s for it to load and the keyboard to appear, then find_element{element_type:\"textfield\"} to locate the REAL input field before typing."
            )
        }
        return (result, nil)
    }

    /// find_and_tap — like tap_element, but always uses the native
    /// `XCUIElement.tap()` (no synthesized-event shortcut). Slower but
    /// works on SwiftUI List/ForEach rows that ignore synthesized taps —
    /// exactly the case Minis's Debug Server forwards to us. Same match
    /// semantics as tap_element (element_id may be a label OR identifier,
    /// optional match:'contains' for partial substring).
    private func findAndTap(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let elementId = cmd.elementId else {
            return (nil, JSONRPCError(code: -32602, message: "find_and_tap requires an 'element_id' (accessibility label or identifier); pair with match:'contains' for partial text.", data: nil))
        }
        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        guard let (element, match, _) = locateElement(query: elementId, type: cmd.elementType,
                                                     bundleId: cmd.bundleId, matchMode: matchMode) else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_and_tap: no element matching '\(elementId)'\(cmd.elementType.map { " of type '\($0)'" } ?? ""). Try match:'contains', or a different label from page_source.",
                data: nil
            ))
        }
        guard element.isHittable else {
            let f = element.frame
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_and_tap: element '\(elementId)' exists but is not hittable (off-screen, covered, or zero-size). Scroll it into view (scroll_to_element).",
                data: ["x": .double(f.midX), "y": .double(f.midY)]
            ))
        }
        // Native tap — drives the OS's real touch pipeline via XCTest. This
        // is why we exist: it works on SwiftUI Lists where the synthesized
        // fastTap path doesn't. Slower (may take a few hundred ms to a couple
        // of seconds if the tap navigates), but reliable.
        let f = element.frame
        let label = element.label
        element.tap()
        return ([
            "message": .string("find_and_tap '\(label.isEmpty ? elementId : label)' via native XCUIElement.tap()"),
            "matched": .string(String(describing: match)),
            "frame": .object([
                "x": .double(f.origin.x), "y": .double(f.origin.y),
                "w": .double(f.width),    "h": .double(f.height),
            ]),
        ], nil)
    }

    private func tapElement(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let elementId = cmd.elementId else {
            return (nil, JSONRPCError(code: -32602, message: "tap_element requires an 'element_id' (accessibility label or identifier)", data: nil))
        }

        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        guard let (element, _, _) = locateElement(query: elementId, type: cmd.elementType,
                                                  bundleId: cmd.bundleId, matchMode: matchMode) else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "No element matching '\(elementId)'\(cmd.elementType.map { " of type '\($0)'" } ?? ""). " +
                    "The label may differ from on-screen text (check page_source), or the element needs scrolling into view (use scroll_to_element). Try match:'contains', or fall back to screenshot + coordinate tap.",
                data: nil
            ))
        }
        guard element.isHittable else {
            let f = element.frame
            return (nil, JSONRPCError(
                code: -32602,
                message: "Element '\(elementId)' exists but is not hittable (off-screen, covered, or zero-size). " +
                    "Scroll it into view (scroll_to_element) or tap its center by coordinate: (\(Int(f.midX)), \(Int(f.midY))).",
                data: ["x": .double(f.midX), "y": .double(f.midY)]
            ))
        }

        // Tap by synthesized event a few pt off the element's center (fast, no
        // post-event settling, slightly humanized) rather than XCUIElement.tap(),
        // which can run ~4s when the tap navigates and has coincided with teardown.
        let f = element.frame
        let label = element.label
        let (tx, ty) = humanizedPoint(in: f)
        let r = fastHandler.fastTap(x: tx, y: ty)
        if r.1 != nil { element.tap() }   // fallback only if synthesized tap failed
        return (["message": .string("Tapped element '\(label.isEmpty ? elementId : label)' at (\(Int(tx)),\(Int(ty)))")], nil)
    }

    private func findElement(id: String, type: String?) -> XCUIElement {
        switch type?.lowercased() {
        case "button":               return app.buttons[id]
        case "textfield", "text_field": return app.textFields[id]
        case "textview", "text_view":   return app.textViews[id]
        case "label", "static_text":    return app.staticTexts[id]
        case "image":                return app.images[id]
        case "cell":                 return app.cells[id]
        case "switch":               return app.switches[id]
        case "icon":                 return app.icons[id]
        default:
            return app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
    }

    // MARK: - Drag

    private func drag(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        // Endpoints can be given as coordinates OR as refs (from_ref/to_ref),
        // which resolve to the element's center. Refs take precedence.
        var fromX = cmd.fromX, fromY = cmd.fromY, toX = cmd.toX, toY = cmd.toY
        if let r = cmd.fromRef {
            let (el, err) = resolveRefForAction(r)
            if let err = err { return (nil, err) }
            fromX = Double(el!.frame.midX); fromY = Double(el!.frame.midY)
        }
        if let r = cmd.toRef {
            let (el, err) = resolveRefForAction(r)
            if let err = err { return (nil, err) }
            toX = Double(el!.frame.midX); toY = Double(el!.frame.midY)
        }
        guard let fromX = fromX, let fromY = fromY, let toX = toX, let toY = toY else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "drag requires from_x/from_y/to_x/to_y (points) or from_ref/to_ref (element refs). " +
                    "For a simple flick use 'swipe' instead.",
                data: nil
            ))
        }
        if let err = validateCoordinate(x: fromX, y: fromY, context: "drag start") { return (nil, err) }
        if let err = validateCoordinate(x: toX, y: toY, context: "drag end") { return (nil, err) }

        let duration = cmd.duration ?? 0.5

        let eventRecord = XCSynthesizedEventRecord(name: "Drag")
        let startPoint = CGPoint(x: fromX, y: fromY)
        let endPoint = CGPoint(x: toX, y: toY)
        let eventPath = XCPointerEventPath(forTouchAt: startPoint, offset: 0.0)
        eventPath.pressDown(atOffset: 0.0)
        eventPath.move(to: endPoint, atOffset: duration)
        eventPath.liftUp(atOffset: duration + 0.05)
        eventRecord.add(eventPath)

        do {
            try eventRecord.synthesize()
            return ([
                "message": .string("Dragged from (\(fromX),\(fromY)) to (\(toX),\(toY))"),
                "screen": coordinateHint,
            ], nil)
        } catch {
            return (nil, .serverError("Drag failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Wait

    private func wait(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let duration = cmd.duration ?? 1.0
        usleep(useconds_t(duration * 1_000_000))
        return (["message": .string("Waited \(duration)s")], nil)
    }
}
