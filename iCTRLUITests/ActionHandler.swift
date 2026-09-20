import XCTest
import UIKit
import Vision

extension XCUIElement {
    /// `exists`, without the ability to kill the runner.
    ///
    /// The property looks like a field read but is a query XCTest resolves in
    /// the target app across IPC, and it raises an Obj-C NSException when that
    /// resolution fails. Swift can't intercept that — `try?` catches only Swift
    /// `throws` — so it unwinds into XCTest's terminate handler and the process
    /// dies with SIGABRT.
    ///
    /// Observed on iOS 16.1 (iPhone 8 Plus): `exists` threw from inside
    /// `-[XCTActivityRecordStack didFinishActivity:]` on a background queue and
    /// took the runner down mid-`find_element`. Older XCTest records an activity
    /// per query and is stricter about that stack being balanced, so every one
    /// of these reads is a crash risk on older systems even though the same code
    /// has run for months on iOS 26.
    var safeExists: Bool {
        ForegroundApp.safeBoolProperty("exists", ofElement: self, fallback: false)
    }

    /// `isHittable`, guarded the same way and for the same reason.
    var safeIsHittable: Bool {
        ForegroundApp.safeBoolProperty("isHittable", ofElement: self, fallback: false)
    }
}

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
        return el.safeExists ? el : nil
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

    /// Browsers render their page into a web view that XCUITest does not walk:
    /// the accessibility tree stops at the browser chrome, so page_source returns
    /// a few dozen anonymous `Other` nodes and NO page content. Element lookups
    /// therefore always miss, and the generic "try scroll/contains" advice sends
    /// the caller in circles. Detect it so the error can say what actually works
    /// (screenshot + tap by coordinate) instead.
    private static let webViewHostBundleIds: Set<String> = [
        "com.apple.mobilesafari",
        "com.google.chrome.ios",
        "com.microsoft.msedge",
        "org.mozilla.ios.Firefox",
        "com.apple.SafariViewService",
    ]

    private func foregroundIsWebViewHost() -> Bool {
        guard let bid = resolveForegroundBundleId() else { return false }
        return Self.webViewHostBundleIds.contains(bid)
    }

    /// Appended to lookup failures in a browser — the one piece of advice that
    /// actually recovers the situation.
    private static let webViewAdvice =
        " ⚠️ The foreground app is a BROWSER: web page content is NOT exposed to the " +
        "accessibility tree, so find_element/page_source can never see links, buttons or text in the page " +
        "(page_source returns only browser chrome). Do NOT retry with scroll_to_element or match:'contains' — " +
        "they cannot help here. Next: call screenshot, read the target's position off the image, convert " +
        "pixel→point by dividing by the `scale` field in that same screenshot response, then tap{x,y}."

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
        // Refuse to cache a compatibility-mode reading. The runner has no launch
        // storyboard, so a size sourced from UIScreen (or an app.frame read
        // before SpringBoard is attached) comes back 320x480 on every device.
        // Caching that once would silently mis-scale screenshots AND shift every
        // tap coordinate for the rest of the session — the failure this guard
        // exists to prevent. Better to re-read next call than to lock in a lie.
        guard !Self.isCompatibilityModeSize(frame) else {
            iCTRLUITests.logBuffer.append(
                "⚠️ screen size read as \(Int(frame.width))x\(Int(frame.height)) "
                + "(iOS compatibility-mode default) — not caching; retrying on next call")
            return frame
        }
        cachedPointSize = frame
        return frame
    }

    /// The 320x480 (and 320x568) sizes iOS hands an app that has no launch
    /// storyboard. Never a real modern device's point size.
    private static func isCompatibilityModeSize(_ r: CGRect) -> Bool {
        let known: [(CGFloat, CGFloat)] = [(320, 480), (320, 568)]
        return known.contains { $0 == r.width && $1 == r.height }
    }

    /// Device scale factor (points → pixels). UIScreen access does NOT trigger
    /// quiescence.
    ///
    /// NOTE: `UIScreen.main.bounds` must NEVER be used for the point size here.
    /// The XCUITest runner ships without a launch storyboard, so iOS runs it in
    /// compatibility mode and reports a 320x480 screen no matter the hardware —
    /// use `pointSize` (backed by `app.frame`, which reads true device geometry
    /// through the accessibility server). `.scale` is unaffected by compatibility
    /// mode and stays correct, which is the only reason this one is safe.
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
            // Live health. Sustained capture heats the device and iOS throttles
            // it, so thermal_state explains a stream that is slowing down.
            "system": .object(systemMetrics()),
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
            // The bound app exited (closed or reclaimed). Don't dead-end every
            // later action on "you must relaunch it": clear the binding so we fall
            // back to the live foreground app (global mode), and let THIS action
            // proceed against whatever is now frontmost. We deliberately do NOT
            // auto-relaunch — that would be a fresh cold start with lost context,
            // silently doing the wrong thing. Re-bind explicitly with launch_app
            // if/when the caller wants that app again.
            boundBundleId = nil
            lastBoundActivateAt = 0
            return (nil, "The previously bound app '\(bound)' had exited, so it was unbound; " +
                "actions now target the live foreground app. Re-open it with " +
                "launch_app{bundle_id:\"\(bound)\"} to bind to it again.")
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
        case "snapshot_api":
            var out: [String: JSONValue] = [:]
            for (k, v) in ForegroundApp.snapshotAPICapabilities() {
                out[String(describing: k)] = .string(String(describing: v))
            }
            return (out, nil)
        case "reset":
            return reset()
        case "snapshot_bench":
            return snapshotBench(cmd)
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
        case "screen_text", "ocr":
            return screenText(cmd)
        case "tap_element":
            return tapElement(cmd)
        case "find_and_tap":
            return findAndTap(cmd)
        case "drag":
            return drag(cmd)
        case "wait":
            return wait(cmd)
        default:
            return (nil, Self.unknownMethodError(method))
        }
    }

    /// Every dispatchable method name, including aliases — the source of truth for
    /// "did you mean" suggestions. Keep in sync with the switch above.
    private static let knownMethods: [String] = [
        "activate_app", "clear_text", "device_info", "double_tap", "drag", "snapshot_api",
        "find_and_tap", "find_element", "home", "installed_apps", "is_locked",
        "launch_app", "list_apps", "lock", "long_press", "open", "open_url",
        "page", "page_down", "page_source", "page_up", "reset", "resolve_app",
        "screenshot", "scroll", "scroll_to", "scroll_to_element", "search_app",
        "search_apps", "snapshot_bench", "swipe", "tap", "tap_element",
        "screen_text", "ocr", "terminate_app", "type", "ui_tree", "unlock", "view_tree", "wait",
    ]

    /// Unknown method → name the closest matches and point at /schema, so a caller
    /// that guessed (`type_text` for `type`) recovers on the next call instead of
    /// guessing again.
    private static func unknownMethodError(_ attempted: String) -> JSONRPCError {
        let want = attempted.lowercased()
        // Cheap similarity: shared prefix, or one name containing the other —
        // enough to catch the realistic near-misses without a full edit distance.
        let suggestions = knownMethods.filter { known in
            known.contains(want) || want.contains(known)
                || known.prefix(4) == want.prefix(4)
        }.prefix(4)

        var message = "Method '\(attempted)' does not exist."
        if !suggestions.isEmpty {
            message += " Did you mean: \(suggestions.joined(separator: ", "))?"
        }
        message += " Next: GET /schema (unauthenticated) for the full method list with parameters" +
            " — one call, and it prevents further guessing."
        return JSONRPCError(code: -32601, message: message, data: nil)
    }

    // MARK: - Device

    /// Live system health: thermal state, memory, CPU.
    ///
    /// What iOS actually allows differs per metric, so each one reports whether
    /// it worked instead of quietly returning zero:
    ///   - thermal state and total RAM come from public ProcessInfo API;
    ///   - this process's footprint and CPU come from task/thread info, which a
    ///     sandboxed app may always read about ITSELF;
    ///   - system-wide free memory and CPU need a host port, which the sandbox
    ///     usually denies. Those keys are simply absent when denied.
    ///
    /// Relevant to this project specifically: sustained capture heats the device
    /// and iOS then throttles it, which is what drags the stream's frame rate
    /// down over minutes. `thermal_state` is the signal for that.
    private func systemMetrics() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let pi = ProcessInfo.processInfo

        let thermal: String
        switch pi.thermalState {
        case .nominal:  thermal = "nominal"
        case .fair:     thermal = "fair"
        case .serious:  thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        out["thermal_state"] = .string(thermal)
        out["low_power_mode"] = .bool(pi.isLowPowerModeEnabled)
        out["total_memory_mb"] = .int(Int(pi.physicalMemory / 1024 / 1024))
        out["processor_count"] = .int(pi.activeProcessorCount)

        // This process's memory footprint — the number iOS uses for jetsam.
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let vmKR = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        if vmKR == KERN_SUCCESS {
            out["process_memory_mb"] = .int(Int(vmInfo.phys_footprint / 1024 / 1024))
        }

        // This process's CPU, summed across its threads. Can exceed 100% on
        // multiple cores.
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let list = threads {
            var total = 0.0
            for i in 0..<Int(threadCount) {
                var ti = thread_basic_info()
                var tc = mach_msg_type_number_t(THREAD_INFO_MAX)
                let kr = withUnsafeMutablePointer(to: &ti) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(tc)) {
                        thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &tc)
                    }
                }
                if kr == KERN_SUCCESS, ti.flags & TH_FLAGS_IDLE == 0 {
                    total += Double(ti.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                }
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size))
            out["process_cpu_percent"] = .double((total * 10).rounded() / 10)
        }

        // System-wide free memory. Needs a host port; absent if the sandbox says no.
        var vmStats = vm_statistics64_data_t()
        var statCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let statKR = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(statCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &statCount)
            }
        }
        if statKR == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            out["system_free_memory_mb"] = .int(Int(UInt64(vmStats.free_count) * page / 1024 / 1024))
        }

        out.merge(diskMetrics()) { a, _ in a }
        out.merge(batteryMetrics()) { a, _ in a }

        // Screen/app state. Without these a caller that gets a black screenshot or
        // a tap that "worked" but changed nothing has no way to tell a locked
        // device from a broken one, and no way to know which app it is actually
        // driving — both cost a round of blind guessing to diagnose.
        out["screen_locked"] = .bool(LockStateMonitor.shared().isLocked)
        if let fg = resolveForegroundBundleId() {
            out["foreground_app"] = .string(fg)
            if Self.webViewHostBundleIds.contains(fg) {
                out["foreground_is_browser"] = .bool(true)
            }
        }
        return out
    }

    /// Storage capacity and free space.
    ///
    /// Two different "free" numbers are reported because iOS answers the question
    /// twice. `volumeAvailableCapacityForImportantUsage` is what Settings shows
    /// and what an app can actually expect to get — it counts space iOS would
    /// reclaim by evicting purgeable caches. The raw `volumeAvailableCapacity` is
    /// usually much smaller and looks alarming without meaning anything is wrong.
    /// Reporting only one of them invites the wrong conclusion, so both ship.
    private func diskMetrics() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return out }

        let mb = { (bytes: Int64) in Int(bytes / 1024 / 1024) }
        if let total = values.volumeTotalCapacity {
            out["disk_total_mb"] = .int(mb(Int64(total)))
        }
        // The realistic figure, and the one to compare against Settings.
        if let important = values.volumeAvailableCapacityForImportantUsage {
            out["disk_free_mb"] = .int(mb(important))
        }
        // The conservative figure: excludes anything iOS would have to purge.
        if let available = values.volumeAvailableCapacity {
            out["disk_available_now_mb"] = .int(mb(Int64(available)))
        }
        if let total = values.volumeTotalCapacity, total > 0,
           let important = values.volumeAvailableCapacityForImportantUsage {
            let usedPct = (1.0 - Double(important) / Double(total)) * 100.0
            out["disk_used_percent"] = .double((usedPct * 10).rounded() / 10)
        }
        return out
    }

    /// Battery level and charging state.
    ///
    /// Monitoring has to be enabled before iOS populates these, and it is left on
    /// afterwards: the runner is long-lived, and toggling it per call would make
    /// every reading the first one (iOS returns -1 until the first update lands).
    private func batteryMetrics() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }

        // -1 means "not known yet" — report nothing rather than a bogus level.
        let level = device.batteryLevel
        if level >= 0 { out["battery_percent"] = .int(Int((level * 100).rounded())) }

        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full:     state = "full"
        case .unplugged: state = "unplugged"
        case .unknown:  state = "unknown"
        @unknown default: state = "unknown"
        }
        if device.batteryState != .unknown { out["battery_state"] = .string(state) }
        return out
    }

    /// Drop cached automation state so the next UI call starts clean.
    ///
    /// Intended for use after the accessibility connection to the foreground app
    /// drops (`kAXErrorServerNotFound`), which otherwise leaves every UI method
    /// timing out. What this can and can't do is worth being precise about:
    ///
    /// It clears OUR state — element refs (now pointing into a dead tree), the
    /// sticky bound app, and the cached screen size. It cannot restart XCTest's
    /// accessibility session; that belongs to the framework and has no public
    /// reset. The reconnect, if it happens, comes from the next query against a
    /// foregrounded app. So this is a cheap thing to try before the guaranteed
    /// fix (relaunch the runner via config{stop_server:true}), not a promise.
    ///
    /// Deliberately free of XCUITest calls, so it stays answerable when the UI
    /// queue is wedged — a recovery method that queues behind the fault it
    /// recovers from would be useless.
    func reset() -> ([String: JSONValue]?, JSONRPCError?) {
        let refCount = refStore.count
        refStore.removeAll()
        let previouslyBound = boundBundleId
        boundBundleId = nil
        cachedPointSize = nil

        iCTRLUITests.logBuffer.append("♻️ reset — cleared \(refCount) refs"
                                    + (previouslyBound.map { ", unbound \($0)" } ?? ""))

        // Report the foreground app so the caller can decide what to re-launch;
        // this reads a private API, not XCUITest, so it can't block.
        let foreground = ForegroundApp.currentBundleID()
        var out: [String: JSONValue] = [
            "reset": .bool(true),
            "cleared_refs": .double(Double(refCount)),
            "hint": .string(
                "Cleared cached refs, the sticky app binding and the screen-size cache. "
                + "Re-establishing the accessibility connection is up to XCTest: call launch_app "
                + "(or activate_app) on the target app, then retry. If UI calls still time out, "
                + "the runner itself must be restarted — config{stop_server:true}, then relaunch it."
            ),
        ]
        if let prev = previouslyBound { out["unbound"] = .string(prev) }
        if let fg = foreground { out["foreground_app"] = .string(fg) }
        return (out, nil)
    }

    private func deviceInfo() -> ([String: JSONValue]?, JSONRPCError?) {
        let device = UIDevice.current
        // Must be app.frame: it is the only source that reports TRUE device
        // geometry from inside the runner (see compatibilityModeScreenBounds).
        // This is why device_info stays on the main-thread/UI path despite the
        // cost — reporting a wrong coordinate space is worse than being slow,
        // since every tap the client sends is computed against these numbers.
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
            // Build identity. Two installs can share a server_version (the bump
            // is manual), so this is what tells you whether the binary you just
            // deployed is the one answering.
            "build": .string(RPCMethodRegistry.buildTimestamp),
            "protocol_version": .int(RPCMethodRegistry.protocolVersion),
            "capabilities": .array(RPCMethodRegistry.capabilityTags.map { .string($0) }),
            // Lets a caller holding an older copy of the manual notice it. An
            // installed skill is a snapshot from whenever it was fetched and has
            // no other way to learn the device moved on underneath it, so the
            // device mentions its version on the one call every client makes.
            // Advisory: the caller decides whether the gap actually matters.
            "skill_version": .string(RPCMethodRegistry.serverVersion),
            "skill_update_hint": .string(
                "Advisory, not required. Compare this skill_version with the one in your SKILL.md frontmatter and "
                + "judge by semver: equal, or a PATCH difference (1.6.1 vs 1.6.2) — carry on, nothing you call has changed. "
                + "MINOR difference (1.5.x vs 1.6.x) — new methods or fields exist; refresh if something you need seems missing. "
                + "MAJOR difference, or protocol_version != the value your client implements — refresh before continuing, "
                + "since the wire format itself may have moved. To refresh (unauthenticated, no pairing needed): "
                + "curl -o SKILL.md http://<host>:8200/skill && curl -o ictrl_rpc.py http://<host>:8200/skill/clients/python, "
                + "then re-read SKILL.md. Refresh both together — a stale client hand-rolls the envelope crypto. "
                + "Prefer feature-detecting against `capabilities` over version comparison for individual features."
            ),
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
                "screen_scale (\(s)) is the PANEL's ratio — do NOT divide screenshot pixels by it. " +
                "A screenshot defaults to scale 2 (\(Int(frame.width * 2))×\(Int(frame.height * 2)) px), " +
                "so dividing by \(s) would put a tap far off target. Always read `scale` from the " +
                "screenshot response itself and use point = pixel / that scale. " +
                "Bottom tab bars sit above the home-indicator safe area (~y \(Int(frame.height) - 60)–\(Int(frame.height) - 20))."
            ),
            // Live device health. This is the call /remote polls for its status
            // overlay, and the documented home for these metrics — they were
            // previously attached only to coordinateHint, which rides along with
            // tap/swipe responses and so never reached a plain device_info.
            "system": .object(systemMetrics()),
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
        // JPEG by default. The client has to run the whole response body through
        // the envelope's HMAC keystream, so response SIZE is what dominates a
        // screenshot's end-to-end cost — a PNG of a UI screen is typically 5-10x
        // larger than a visually equivalent JPEG, and that multiplier lands
        // directly on the client's decrypt loop. PNG stays available for callers
        // that need lossless output (pixel diffing, OCR on fine text).
        let wantPNG = (cmd.format ?? "jpeg").lowercased() == "png"
        let quality = min(max(cmd.quality ?? 0.6, 0.1), 1.0)
        let targetPixels = CGSize(width: targetPixelW, height: targetPixelH)
        let imageData = wantPNG
            ? Self.encodePNG(fullImage, targetPixels: targetPixels)
            : Self.encodeJPEG(fullImage, targetPixels: targetPixels, quality: quality)
        let base64 = imageData.base64EncodedString()

        var result: [String: JSONValue] = [
            "format": .string(wantPNG ? "png" : "jpeg"),
            "encoding": .string("base64"),
            "data": .string(base64),
            "bytes": .double(Double(imageData.count)),
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
                "x = px / \(targetScale), y = py / \(targetScale)."
            ),
            // Its own field, not a clause buried in the coordinate maths above.
            // Screenshots are the most over-used tool here: a model reads one,
            // eyeballs a control, converts pixels to points and taps — and every
            // one of those steps can be wrong in a way nothing reports. Measured
            // in this project: a tap meant for a destination field landed on the
            // nav bar, and a stray tap during scrolling added a product to a
            // cart. find_element returns a ref that re-resolves the live element,
            // so it cannot drift and needs no conversion at all.
            "prefer_instead": .string(
                "DON'T tap from this image if you can avoid it. To act on a control: " +
                "find_element{element_id:\"<label>\"} → tap{ref} — a ref re-resolves the live element, " +
                "survives scrolling/animation, and skips the pixel→point conversion entirely. " +
                "To understand the layout: page_source{visible_only:true} returns every on-screen " +
                "element with its type, label and exact frame, and is usually FASTER than a screenshot " +
                "(~100ms vs ~150ms) as well as far smaller. " +
                "Screenshots earn their place when the tree can't answer you: an element with no label " +
                "(icon-only buttons, images), a layout question you can only judge visually, " +
                "verifying that an action actually landed, or when page_source comes back sparse " +
                "(check its ax_coverage / sparse_hint / viewport_warning fields) — most often a web view, " +
                "where page content never reaches the accessibility tree at all."
            ),
        ]
        if !wantPNG { result["quality"] = .double(quality) }
        var out = result
        if let bid = scopedTo {
            out["scoped_to"] = .string(bid)
            out["scope"] = .string("app")
        } else {
            out["scope"] = .string("screen")
        }
        return (out, nil)
    }

    /// Render a UIImage to JPEG at the requested pixel size and quality.
    ///
    /// Shares the resize path with `encodePNG`; only the final serialization
    /// differs. `opaque = true` matters here — a screen capture has no alpha, and
    /// telling the renderer so avoids a needless alpha channel.
    private static func encodeJPEG(_ image: UIImage, targetPixels: CGSize, quality: Double) -> Data {
        let resized = resize(image, targetPixels: targetPixels)
        return resized.jpegData(compressionQuality: CGFloat(quality))
            ?? image.jpegData(compressionQuality: CGFloat(quality))
            ?? Data()
    }

    /// Downscale to an exact pixel size. Shared by the PNG and JPEG encoders.
    private static func resize(_ image: UIImage, targetPixels: CGSize) -> UIImage {
        let w = max(1, Int(targetPixels.width.rounded()))
        let h = max(1, Int(targetPixels.height.rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1               // we specify size in raw pixels
        format.opaque = true
        let size = CGSize(width: w, height: h)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Render a UIImage to PNG at the requested pixel size (server-side downscale).
    private static func encodePNG(_ image: UIImage, targetPixels: CGSize) -> Data {
        let resized = resize(image, targetPixels: targetPixels)
        return resized.pngData() ?? image.pngData() ?? Data()
    }

    // MARK: - Tap

    /// Resolve a ref for a spatial action, returning the live element or a
    /// descriptive error. Shared by tap/double_tap/long_press.
    private func resolveRefForAction(_ refId: String) -> (XCUIElement?, JSONRPCError?) {
        guard let el = resolveRef(refId) else {
            return (nil, JSONRPCError(code: -32602, message: "ref '\(refId)' no longer resolves — element gone, view changed, or ref expired (refs live 1 hour). Re-find it with find_element/scroll_to_element.", data: nil))
        }
        guard el.safeIsHittable else {
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
            // Synthesized rather than XCUIElement.doubleTap(), for the same
            // reason tap(ref:) synthesizes: the native gesture waits for
            // quiescence on both sides — measured 6230ms here, and it timed out
            // hard enough to trip the UI circuit breaker.
            let f = el!.frame
            let label = el!.label
            let (cx, cy) = humanizedPoint(in: f)
            let r = fastHandler.fastDoubleTap(x: cx, y: cy)
            if r.1 == nil {
                return (["message": .string("Double tapped ref \(refId) ('\(label)')")], nil)
            }
            el!.doubleTap()
            return (["message": .string("Double tapped ref \(refId) ('\(label)') (native)")], nil)
        }
        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "double_tap requires x and y (in points), or a 'ref'", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "double_tap") { return (nil, err) }

        if cmd.fast != false {
            // mode:"separate" sends two independent synthesize calls; the default
            // packs both presses into one event path so the gap is exact.
            let separate = (cmd.matchMode ?? "").lowercased() == "separate"
            let r = separate
                ? fastHandler.fastDoubleTapSeparate(x: x, y: y)
                : fastHandler.fastDoubleTap(x: x, y: y)
            if r.1 == nil {
                return (["message": .string("Double tapped at (\(x), \(y))" +
                                            (separate ? " (two records)" : " (one record)")),
                         "screen": coordinateHint], nil)
            }
        }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.doubleTap()

        return (["message": .string("Double tapped at (\(x), \(y)) (native)"), "screen": coordinateHint], nil)
    }

    private func longPress(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let duration = cmd.duration ?? 2.0
        // ref-first, like tap.
        if let refId = cmd.ref {
            let (el, err) = resolveRefForAction(refId)
            if let err = err { return (nil, err) }
            let label = el!.label
            // Native: a synthesized hold is not recognised as a long press (see
            // the coordinate path below).
            el!.press(forDuration: duration)
            return (["message": .string("Long pressed ref \(refId) ('\(label)') for \(duration)s")], nil)
        }
        guard let x = cmd.x, let y = cmd.y else {
            return (nil, JSONRPCError(code: -32602, message: "long_press requires x and y (in points), or a 'ref'", data: nil))
        }
        if let err = validateCoordinate(x: x, y: y, context: "long_press") { return (nil, err) }

        // Native by default — unlike tap/swipe, a synthesized hold does NOT work.
        // XCPointerEventPath reports the press and the lift (and any samples in
        // between), but UIKit's long-press recognizer never fires: WeChat opened
        // the chat as an ordinary tap, and on a message bubble no action menu
        // appeared, while the native press at the same point produced the full
        // copy/forward/delete menu. Opt in with fast:true if an app disagrees.
        if cmd.fast == true {
            let r = fastHandler.fastLongPress(x: x, y: y, duration: duration)
            if r.1 == nil {
                return (["message": .string("Long pressed at (\(x), \(y)) for \(duration)s (synthesized — " +
                                            "may register as a tap; omit fast:true if no menu appears)"),
                         "screen": coordinateHint], nil)
            }
        }

        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let coordinate = normalized.withOffset(CGVector(dx: x, dy: y))
        coordinate.press(forDuration: duration)

        return (["message": .string("Long pressed at (\(x), \(y)) for \(duration)s (native)"), "screen": coordinateHint], nil)
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

        // Number of screenfuls (default 1). One "page" moves 75% of the height,
        // leaving ~25% overlap between consecutive reads — about 220pt, which is
        // most of a typical feed card (~330pt on RED), so an item on the boundary
        // is fully readable in one of the two reads.
        //
        // Overlap only means something now that the drag actually lands where it
        // is aimed (see the velocity note below). It was 85% with a fixed-duration
        // drag that overshot by up to 61%, so the intended "sliver of overlap"
        // was consumed by overshoot and consecutive reads shared nearly nothing.
        let pages = max(0.1, min(cmd.distance ?? 1.0, 5.0))   // reuse `distance` as page count
        let pageTravel = size.height * 0.75 * pages

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

        // Hold the drag SPEED below the momentum threshold, rather than using a
        // fixed duration. A constant 0.45s meant velocity grew with travel, and
        // iOS starts adding inertia above ~350pt/s — measured on this device:
        //
        //   889pt/s -> moved 1.61x the finger travel
        //   500pt/s -> 1.27x
        //   344pt/s -> 0.97x   (precise)
        //   275pt/s -> 0.97x   (precise)
        //
        // So the old "NO iOS momentum" claim held only for short drags. At one
        // full page it overshot past a whole screen, which silently ate the
        // overlap between consecutive reads — items could pass between two
        // page_source calls with nothing to indicate it.
        //
        // 300pt/s keeps a margin below the threshold. The floor stops very short
        // drags from becoming absurdly slow; the ceiling bounds the worst case,
        // since an XCUITest gesture blocks the (serial) UI queue while it runs.
        let travel = abs(fromY - toY)
        let dragDuration = min(max(travel / 300.0, 0.30), 2.5)
        let r = fastHandler.fastSwipe(fromX: cx, fromY: fromY, toX: cx, toY: toY, duration: dragDuration)
        if r.1 != nil { return r }
        return ([
            "message": .string("Paged \(goingDown ? "down" : "up") \(pages) screenful(s) — 75% of the screen each, so consecutive reads overlap by ~25% and nothing falls between them. Precise scroll (no momentum). Re-read with page_source/screenshot."),
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
        guard ["up", "down", "left", "right"].contains(direction) else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "Invalid scroll direction '\(direction)'. Use one of: up, down, left, right. " +
                    "Note: direction is the finger movement — 'up' reveals content below.",
                data: nil
            ))
        }

        // Synthesized by default, like tap/swipe. app.swipeUp() and friends run
        // XCTest's element-aware gesture, which waits for quiescence before AND
        // after the event — the same settling that cost find_and_tap ~7.6s per
        // call. A synthesized drag over the same distance doesn't wait at all.
        // fast:false keeps the native gesture for apps where synthesis doesn't
        // land (SwiftUI Lists being the known case).
        if cmd.fast != false {
            let s = pointSize
            let midX = s.width / 2
            // Vertical travel stays inside the middle band (30%..80% of height).
            // Starting a downward drag near the top is read as a pull-down by
            // several apps — WeChat opened its mini-program panel instead of
            // scrolling — and the bottom eighth is the home-indicator area.
            let topY = s.height * 0.30, botY = s.height * 0.80
            let dx = s.width * 0.275
            let midY = s.height / 2
            let (fx, fy, tx, ty): (Double, Double, Double, Double)
            switch direction {
            case "up":    (fx, fy, tx, ty) = (midX, botY, midX, topY)
            case "down":  (fx, fy, tx, ty) = (midX, topY, midX, botY)
            case "left":  (fx, fy, tx, ty) = (midX + dx, midY, midX - dx, midY)
            default:      (fx, fy, tx, ty) = (midX - dx, midY, midX + dx, midY)
            }
            let r = fastHandler.fastSwipe(fromX: fx, fromY: fy, toX: tx, toY: ty, duration: 0.3)
            if r.1 == nil {
                return (["message": .string("Scrolled \(direction) (synthesized)"),
                         "screen": coordinateHint], nil)
            }
            // fall through to the native gesture when synthesis failed
        }

        switch direction {
        case "up":    app.swipeUp()
        case "down":  app.swipeDown()
        case "left":  app.swipeLeft()
        default:      app.swipeRight()
        }
        return (["message": .string("Scrolled \(direction) (native)")], nil)
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
            "VERIFY BEFORE RETRYING — screenshot and check whether the text landed; typing again would enter it twice. " +
            "If it did NOT land, tap a real textfield first (find_element{element_id:\"<placeholder text>\", element_type:\"textfield\", match:\"contains\"} → tap{ref}), wait ~1s, then type again. " +
            "A home-screen 'search bar' is often a button that opens a separate search page."
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

        // Typing into a field that already has content APPENDS, and nothing about
        // the result says so: the response reports the text you asked for, the
        // field now holds old+new, and a search silently runs on the wrong query.
        // Hit for real here — searching "椰子汁" in a box still holding "黄桃"
        // searched for "黄桃椰子汁". So read the field first and say what happened.
        //
        // Read-only and cheap: the same snapshot lookup clearFocusedField() does,
        // skipped entirely when clear:true (the field is about to be emptied).
        var preexisting = ""
        if !clearFirst, !text.isEmpty {
            preexisting = focusedFieldValue() ?? ""
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
        // Surfaced on BOTH return paths: the append is silent otherwise, and the
        // response would happily report the text the caller asked for while the
        // field holds something else entirely.
        func appendWarning() -> String? {
            guard !preexisting.isEmpty else { return nil }
            return "The field already contained \"\(preexisting)\", so it now reads "
                + "\"\(preexisting + text)\" — typing APPENDS, it does not replace. "
                + "If you meant to replace, call type{clear:true, text:\"...\"} instead. "
                + (submit ? "NOTE a Return was already sent, so any search ran on the combined text." : "")
        }

        if cmd.fast == true {
            let r = fastHandler.fastTypeText(text)
            if submit, r.1 == nil { sendReturnKey() }
            if var data = r.0 {
                let prefix = clearFirst ? "Cleared then typed: " : "Typed: "
                data["message"] = .string(text.isEmpty && clearFirst ? "Cleared focused field" : (prefix + text + (submit ? " + Return" : "")))
                if let a = appendWarning() { data["append_warning"] = .string(a) }
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
            if let a = appendWarning() { out["append_warning"] = .string(a) }
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

    /// Current text of the focused field, or nil if it can't be read.
    ///
    /// Best-effort by nature: plenty of apps put their search box in a WebView or
    /// a custom control that never reports hasKeyboardFocus, and nil there means
    /// "unknown", NOT "empty" — callers must not treat the two the same.
    private func focusedFieldValue() -> String? {
        guard let bid = resolveForegroundBundleId() else { return nil }
        let target = XCUIApplication(bundleIdentifier: bid)
        for query in [target.textFields, target.secureTextFields, target.searchFields] {
            let el = query.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
            if el.safeExists, let v = el.value as? String { return v }
        }
        return nil
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
            if focused.safeExists, let v = focused.value as? String { count = v.count }
            if count == 0 {
                let sv = target.secureTextFields.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
                if sv.safeExists, let v = sv.value as? String { count = v.count }
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
                "tap a real textfield first (find_element{element_id:\"<placeholder text>\", element_type:\"textfield\", match:\"contains\"} → tap{ref}), then clear_text again.")
        }
        return (out, nil)
    }

    // MARK: - Device Buttons

    private func pressHome() -> ([String: JSONValue]?, JSONRPCError?) {
        // Which app we are leaving. The live detector is first, but it returns
        // nil on iOS 26 (activeApplications is empty there), so fall back to the
        // sticky binding — the app we most recently launched is the one still in
        // front in practice, and it is the only handle we have to verify against.
        let before = ForegroundApp.currentBundleID() ?? boundBundleId
        let springboard = "com.apple.springboard"

        // `press(.home)` normally blocks until SpringBoard is frontmost — but that
        // wait lives in XCTest's quiescence machinery, which this runner no-ops
        // globally (see QuiescenceDisabler) to stop taps stalling for seconds. So
        // the press is delivered and we return before the transition happens,
        // which reads as "Home did nothing". Verify the result ourselves instead
        // of reporting success blind.
        _ = ObjCException.catching { XCUIDevice.shared.press(.home) }

        // Verify via the app we are trying to LEAVE, not via "is SpringBoard
        // frontmost". The private activeApplications detector returns nil on
        // iOS 26 whatever is in front, so a check built on it passes instantly
        // and reports success for a press that did nothing. XCUIApplication.state
        // is public, works, and answers the question that actually matters: did
        // the app we were in stop being foreground?
        func leftForeground() -> Bool {
            guard let bid = before, bid != springboard else {
                // Nothing was in front (already home), or SpringBoard itself —
                // there is nothing to leave, so the press has nothing to prove.
                return true
            }
            let state = AppState(rawValue: ForegroundApp.appState(forBundleID: bid)) ?? .unknown
            return state != .foreground
        }

        // Poll rather than sleep a fixed interval: the animation is ~300-500ms but
        // varies with what's on screen, and a fixed wait either lies or wastes time.
        var landed = false
        for _ in 0..<20 {
            if leftForeground() { landed = true; break }
            usleep(100_000)
        }

        // Fallback: activate SpringBoard directly. `press(.home)` is a no-op on
        // iOS 26 here — the button event goes nowhere on a device that has no
        // physical Home button — whereas activating SpringBoard as an app is a
        // normal foreground switch and does not depend on button synthesis.
        if !landed {
            // This is what WebDriverAgent actually ships for its home-screen
            // route (fb_switchToSystemApplicationWithError): activate SpringBoard
            // as an app, launching it if it isn't running. WDA dropped
            // pressButton: for this years ago precisely because the press was
            // async and unreliable — which matches what this device does.
            iCTRLUITests.logBuffer.append("🏠 press(.home) had no effect — activating SpringBoard instead")
            _ = ObjCException.catching { _ = ForegroundApp.activateOrLaunchBundleID(springboard) }
            for _ in 0..<20 {
                if leftForeground() { landed = true; break }
                usleep(100_000)
            }
        }

        // Home changes what's in front, so the sticky binding is now stale —
        // leaving it set would silently re-activate the old app on the next
        // element action, undoing the very thing the caller asked for.

        guard landed else {
            return (nil, .serverError(
                "Could not leave '\(before ?? "the foreground app")': both the Home button and "
                + "activating SpringBoard failed to background it. A modal alert or system sheet can hold "
                + "focus — check page_source for a dialog and dismiss it — or the device may be locked "
                + "(call is_locked)."
            ))
        }
        // The caller has explicitly left the app, so the sticky binding must go:
        // leaving it set would silently re-activate that app on the next element
        // action, undoing the thing that was just asked for.
        boundBundleId = nil
        return ([
            "message": .string("Returned to the home screen"),
            "foreground_app": .string(springboard),
            "previous_app": before.map { JSONValue.string($0) } ?? .null,
        ], nil)
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

        // An empty list is NOT proof the app is missing. This enumeration goes
        // through LSApplicationWorkspace, which iOS has been progressively
        // locking down — on iOS 26 it has been observed returning nothing at all
        // on a device with dozens of apps installed. Saying so here matters:
        // otherwise a caller reads count:0 as "not installed" and abandons a
        // task that was perfectly doable.
        var hint = "Use a bundle_id with launch_app. Pass {\"text\":\"大麦\"} to filter, " +
                   "or {\"element_type\":\"all\"} to include system apps."
        if items.isEmpty {
            hint = "⚠️ Empty result — this does NOT mean the app is absent. App enumeration is a " +
                   "private API that newer iOS versions may refuse, returning nothing even when the " +
                   "app IS installed. Do not conclude 'not installed' from this alone. " +
                   Self.appLookupFallbackHint
        }
        return ([
            "count": .int(items.count),
            "apps": .array(items),
            "hint": .string(hint),
        ], nil)
    }

    /// What to do when a bundle id can't be confirmed by lookup. Spotlight is
    /// the authority the OS itself uses, so it finds apps the private
    /// enumeration/catalog paths miss — and it works by NAME, which is what a
    /// user asks for anyway.
    static let appLookupFallbackHint =
        "To verify for real: (1) call launch_app with a candidate bundle_id — an error means genuinely " +
        "not installed, success means it was there all along; or (2) ask iOS itself: call `home`, then " +
        "swipe{direction:\"down\"} from mid-screen to open Spotlight, type the app's NAME, and read the " +
        "result — Spotlight indexes every installed app regardless of API limits. " +
        "Only report 'not installed' after one of these, never from an empty list."

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
            return (nil, JSONRPCError(
                code: -32602,
                message: "resolve_app requires 'text' (the app name / keyword to look up). " +
                    "NOTE: this SEARCHES THE APP STORE — it does not list what is installed on this device, " +
                    "so it must NOT be used to verify an install (it happily returns a different version than the one installed). " +
                    "Next: to check an installed app use list_apps; to search the store retry as resolve_app{text:\"<name>\"}. " +
                    "Full parameter list: GET /schema.",
                data: nil))
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
                // The catalog says what a bundle id IS, never whether it is on
                // this device — it is a static, offline name→id table. A match
                // here reads like confirmation and is not one: resolving 美团 to
                // com.meituan.imeituan succeeded on a device that did not have
                // it, and only launch_app revealed that.
                "hint": .string("Matched the built-in app catalog (instant, offline) — this maps a NAME to a " +
                                "bundle_id and does NOT mean the app is installed here. Confirm by calling " +
                                "launch_app: success proves it, an error means genuinely absent. " +
                                Self.appLookupFallbackHint),
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
            "message": .string("Opened \(bundleId). Actions now target this app until you open another."),
            "bound_app": .string(bundleId),
            // Advisory text goes in `hint`, like every other method — this used
            // to be a separate "advice" key, so a caller reading hints uniformly
            // silently missed it.
            "hint": .string("The app is still launching/rendering — wait 2-3s (call wait), THEN page_source " +
                            "to confirm the UI is stable before locating elements. Acting too early matches " +
                            "placeholder/splash elements or is very slow (cold-start element queries can take 6s+)."),
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
    /// Set when locateElement refused to run because the target app can't be
    /// snapshotted. `locateElement` returns an optional so its callers can treat
    /// "not found" uniformly; this carries the actionable reason alongside, so a
    /// backgrounded app reports as such instead of as a plain miss.
    private var lastLocateError: JSONRPCError?

    /// Snapshot geometry of the node the last locate finally chose
    /// (post-elevation). nil when the live-query fallback matched — that path
    /// has no snapshot, and consumers must read the live element instead.
    /// Same clear-per-call pattern as lastLocateError.
    private var lastLocateSnapFrame: CGRect?
    private var lastLocateSnapLabel: String?

    /// Refuses a snapshot that is going to fail slowly, before it is attempted.
    ///
    /// `snapshot()` on an app that isn't frontmost has no main window to read, so
    /// the accessibility server answers `kAXErrorServerNotFound` — but only after
    /// XCTest's internal ~16s timeout. That call cannot be cancelled, and the RPC
    /// queue is serial, so those 16s block every later request too: one
    /// backgrounded app stalls tap, screenshot, even device_info. Checking the
    /// app's state up front turns that into an instant, actionable error.
    ///
    /// SpringBoard is always readable, so it's exempt.
    static func snapshotPrecheck(bundleId: String?, action: String,
                                 retryWith method: String) -> JSONRPCError? {
        guard let bid = bundleId, bid != "com.apple.springboard" else { return nil }
        let state = AppState(rawValue: ForegroundApp.appState(forBundleID: bid)) ?? .unknown
        switch state {
        case .notRunning:
            return JSONRPCError(code: -32004, message:
                "Can't \(action): app '\(bid)' is not running (it may have crashed or been closed). " +
                "Call launch_app to (re)open it, then retry.", data: nil)
        case .background, .backgroundSuspended:
            return JSONRPCError(code: -32004, message:
                "Can't \(action): app '\(bid)' is in the background, so it has no snapshottable window. " +
                "Bring it to the front first — run one interaction (tap/swipe re-focuses the bound app) or call " +
                "launch_app/activate_app, then retry \(method).", data: nil)
        default:
            return nil  // foreground or unknown → proceed (unknown may still work)
        }
    }

    /// Diagnostic: measures whether XCTest's snapshot request honours a
    /// server-side depth limit, which is the only way to make page_source cheaper
    /// on a large tree — our own max_depth trims after the whole tree has already
    /// been walked and shipped across IPC.
    private func snapshotBench(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let bundleId = cmd.bundleId ?? resolveForegroundBundleId() else {
            return (nil, .serverError("snapshot_bench needs a bundle_id (or a resolvable foreground app)."))
        }
        if let err = Self.snapshotPrecheck(bundleId: bundleId, action: "benchmark the view tree",
                                           retryWith: "snapshot_bench") {
            return (nil, err)
        }
        // element_id names the single property to sample off a node; reading
        // several undocumented getters in one pass hard-crashed the runner.
        ForegroundApp.setProbeSelectorName(cmd.elementId)
        // Negative depth = "use |depth| but SKIP the unbounded baseline". That
        // baseline is an unlimited snapshot which can hang the accessibility
        // connection badly enough that only restarting the runner recovers it,
        // so it must be asked for explicitly (positive max_depth), never default.
        let depth = cmd.maxDepth ?? -8
        guard let raw = ForegroundApp.benchmarkSnapshot(forBundleID: bundleId, maxDepth: depth) else {
            return (nil, .serverError("snapshot_bench unavailable: private XCTest API missing on this build."))
        }
        var out: [String: JSONValue] = ["bundle_id": .string(bundleId)]
        for (k, v) in raw {
            guard let key = k as? String else { continue }
            if let n = v as? NSNumber { out[key] = .int(n.intValue) }
            else if let s = v as? String { out[key] = .string(s) }
        }
        return (out, nil)
    }

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

        if let err = Self.snapshotPrecheck(bundleId: inspectedBundleId, action: "read the view tree",
                                           retryWith: "page_source") {
            return (nil, err)
        }

        // Custom snapshot traversal so we can bound depth / count and filter —
        // debugDescription enumerates & serializes the WHOLE tree (68KB+ on rich
        // pages), which is what makes the first call block for tens of seconds.
        // 40 covers the deepest rows real apps put content at (X's feed cells sit
        // near depth 22) without walking the pathological tail of a long-scrolled
        // list. Unbounded was the old default and is what made a deep feed read
        // take seconds.
        let maxDepth = cmd.maxDepth ?? Self.defaultMaxDepth
        // Hard cap to prevent timeouts even when the caller passes nothing.
        // Raised with max_children: a timeline page already returned ~370 nodes
        // under the old 100-child cap, so leaving this at 500 would just move the
        // truncation from one limit to the other.
        let maxElements = min(cmd.maxElements ?? 2000, 4000)
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
        // Prefer the device-bounded fetch: it applies max_depth/max_children
        // while the app walks its own tree, instead of shipping everything over
        // and trimming here. On a scrolled X timeline that is ~1.6s vs 6.5-8.5s.
        // It rides on private XCTest API that has already moved several times, so
        // any failure falls through to the supported call rather than surfacing.
        // Rendered in Obj-C: the bounded fetch returns an XCElementSnapshot, and
        // bridging it to the XCUIElementSnapshot protocol silently degrades it —
        // frames read as zero and children stop after one level. Filters still
        // run through the protocol path, so fall back when one is active.
        var usedBoundedSnapshot = false
        var boundedBody: String?
        var boundedCount = 0
        var boundedTruncated = false
        // Re-enabled after the empty-tree cause was found. It was never the
        // renderer: the bounded fetch passed standardAttributeNames raw, whose
        // snapshot-domain names ("label") the AX server silently ignores — only
        // the XC_kAXXCAttribute* wire keys fetch content, and snapshot_bench had
        // them while this path didn't. With the same attrs both read full text.
        // Verify snapshot_path:"bounded" appears in responses; a silent fall
        // back to "full" is how a future private-API shift will present.
        // Phase timings: the two costs here are very different in nature — the
        // AX round trip into the target app (fetch) vs. walking the returned
        // tree and building strings (render). A single total can't tell you
        // which one a slow page is paying for, and they have opposite fixes.
        var fetchMs = 0.0
        var renderMs = 0.0
        var childrenUsed = 0
        var ladderSteps: [String] = []
        var ocrFallback: (items: [JSONValue], shotMs: Double, ocrMs: Double)?
        let boundedEnabled = true
        let fetchStart = nowMonotonic

        // maxChildren is one of only TWO knobs the AX server honours at fetch
        // time (the other is maxDepth). Measured: max_elements does NOT bound the
        // fetch — 20 vs 2000 both cost ~90ms, because it truncates after the tree
        // is already materialised. On a wide recycling list, capping children is
        // the only way to stop the server walking thousands of cells at all.
        //
        // An explicit max_children pins the value (one fetch, no ladder) so the
        // parameter stays predictable for callers doing their own tuning.
        let pinnedChildren = cmd.maxChildren.map { max(1, min($0, 5000)) }

        /// One bounded fetch + render at a given child cap.
        func attempt(_ children: Int) -> (body: String, nodes: Int, truncated: Bool)? {
            guard let bid = inspectedBundleId,
                  let bounded = ForegroundApp.boundedSnapshot(
                    forBundleID: bid,
                    maxDepth: maxDepth == Int.max ? Self.defaultMaxDepth : maxDepth,
                    maxChildren: children)
            else { return nil }
            var n = 0
            var t: ObjCBool = false
            let viewport = cmd.visibleOnly == true
                ? CGRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height)
                : CGRect.null
            guard let text = ForegroundApp.renderBoundedSnapshot(
                    bounded,
                    maxDepth: maxDepth == Int.max ? Self.defaultMaxDepth : maxDepth,
                    maxElements: maxElements,
                    visibleRect: viewport,
                    nodesWritten: &n,
                    truncated: &t) else { return nil }
            return (text, n, t.boolValue)
        }

        if boundedEnabled, inspectedBundleId != nil {
            var chosen: (body: String, nodes: Int, truncated: Bool)?
            var usedChildren = 0

            if let pinned = pinnedChildren {
                chosen = attempt(pinned)
                usedChildren = pinned
            } else {
                // Climb only while the probe says list content stops ABOVE the
                // viewport AND the container still has more to give.
                // Start cheap: measured p50 416ms / p90 593ms across 8 apps, and
                // on every app whose list behaves normally this is also COMPLETE
                // (verified at 6-8 pages of scroll in RED/GitHub/JD: identical
                // visible labels to an unbounded read, half the time).
                if let first = attempt(Self.childrenLadder[0]) {
                    chosen = first
                    usedChildren = Self.childrenLadder[0]
                    let coverage = visibleLabelledCoverage(first.body)
                    ladderSteps.append(String(format: "50:%.0f%%", coverage * 100))

                    // Escalate when the tree barely describes the content area. A
                    // ratio rather than a node count: count thresholds encode
                    // assumptions about screen size and row density that break on
                    // the next device or app, while a fraction of the content band
                    // means the same thing everywhere.
                    //
                    // The bar is deliberately LOW. Measured coverages:
                    //   WeChat scrolled  0%  — tree had only nav/tab furniture
                    //   Telegram        11%  — genuinely missing rows
                    //   RED (小红书)     26%  — tree was COMPLETE; every title,
                    //                          author and like count was present.
                    //                          It reads low only because its cards
                    //                          are mostly images, so text covers
                    //                          little area.
                    //   GitHub 92%, App Store 100%, Spotify 89%, X 100%
                    // A 50% bar fired on RED and cost ~400ms of OCR for nothing.
                    // 15% separates the real failures (0-11%) from sparse-but-fine
                    // layouts (26%+) on everything measured.
                    if coverage < 0.15 {
                        // Run the wider fetch and the OCR CONCURRENTLY: serially
                        // they are ~1.2s + ~0.7s, which blows the 1s budget on
                        // exactly the screens that need help most.
                        //
                        // Only the screen CAPTURE is main-thread bound (XCUIScreen,
                        // like every other UI call here); Vision itself is pure
                        // image work. So grab the frame first — cheap, ~106ms —
                        // then let recognition run on a background queue while the
                        // accessibility server walks the bigger tree.
                        // Run OCR INLINE, not on another queue waited on from here.
                        //
                        // The earlier "parallel" version deadlocked the runner: a
                        // page_source is delivered via DispatchQueue.main.sync, so
                        // blocking that main thread on a semaphore while Vision
                        // worked on a background queue left nothing to service work
                        // Vision itself hops to the main queue for. One page_source
                        // on a scrolled WeChat list was enough to kill the HTTP
                        // layer outright — socket still accepting, no responses,
                        // recoverable only by restarting the runner.
                        //
                        // Inline costs ~260ms and cannot deadlock. The theoretical
                        // saving from overlapping it with the wider fetch was ~260ms;
                        // not worth a whole-server hang.
                        //
                        // The wider fetch is also skipped here: measured on exactly
                        // this case it ALSO returns zero on-screen rows, so its
                        // ~1.2s bought nothing. OCR is what actually reads the
                        // screen (tree 6 texts vs OCR 35).
                        ladderSteps.append("500:skipped(ocr)")
                        ocrFallback = runOCR(query: nil, fast: false, minConfidence: 0.3)
                    }
                }
            }

            childrenUsed = usedChildren
            fetchMs = (nowMonotonic - fetchStart) * 1000
            if let got = chosen {
                let renderStart = nowMonotonic
                // Acceptance: a sizeable tree with NO labels at all is the known
                // bad-fetch signature (wrong attribute domain → shape without
                // content), not a plausible real screen. Falling back to the full
                // snapshot there costs seconds; shipping a content-free tree
                // costs the caller a wrong "this page is empty" conclusion.
                //
                // Judged on the RAW fetch: a filter legitimately reduces the tree
                // to a handful of nodes, and judging the filtered text would read
                // that as the bad-fetch signature and fall back for no reason.
                if got.nodes > 1, got.nodes < 40 || got.body.contains("label:") {
                    if filter.active {
                        let (filtered, matches) = Self.filterRenderedTree(got.body, filter: filter)
                        boundedBody = filtered
                        boundedCount = matches
                    } else {
                        boundedBody = got.body
                        boundedCount = got.nodes
                    }
                    boundedTruncated = got.truncated
                    usedBoundedSnapshot = true
                }
                renderMs = (nowMonotonic - renderStart) * 1000
            }
        }

        let appSnap = usedBoundedSnapshot
            ? nil
            : (ForegroundApp.safeSnapshot(ofElement: target) as? XCUIElementSnapshot)
        if let appSnap = appSnap { roots.append(appSnap) }

        let screen = pointSize
        // With the 2s XCTest state-timeout cap, target.snapshot() above is bounded;
        // keep the overlay budget tight too so total page_source stays well under
        // the 6s RPC watchdog even on a busy/animating page.
        let budgetDeadline = nowMonotonic + 2.0
        // Skip entirely when the bounded root is in play: win.snapshot() is the
        // unbounded call, so walking overlays here would pay back the very cost
        // the bounded fetch just avoided. The bounded root is taken at the
        // application element, so it already spans that app's windows.
        let windowCount = usedBoundedSnapshot ? 0 : min(target.windows.count, 6)
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
            if let ws = ForegroundApp.safeSnapshot(ofElement: win) as? XCUIElementSnapshot {
                roots.append(ws)
            }
        }
        guard usedBoundedSnapshot || !roots.isEmpty else {
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
        let cullViewport = cmd.visibleOnly == true
            ? CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
            : CGRect.null
        for root in roots {
            renderSnapshotInto(root, depth: 0, maxDepth: maxDepth, maxElements: maxElements,
                               filter: filter,
                               cullToViewport: cmd.visibleOnly == true, viewportRect: cullViewport,
                               lines: &lines, localCount: &localCount,
                               globalCount: &count, truncated: &truncated, seenFrames: &seenFrames)
            if count >= maxElements { break }
        }

        let body = boundedBody ?? lines.joined(separator: "\n")
        if usedBoundedSnapshot {
            count = boundedCount
            truncated = boundedTruncated
        }

        var hint = "Accessibility tree (types, labels, identifiers, frames in POINTS), including visible overlay " +
            "windows (fixed bottom/floating bars). Frames are {{x,y},{w,h}} — tap an element at its frame center " +
            "(or use find_element to get a ref). If an element is still missing, the app may not expose it — fall " +
            "back to screenshot + coordinate tap."
        if truncated {
            hint = "⚠️ Tree truncated at \(count) nodes (page has more). Narrow the query: " +
                (cmd.visibleOnly == true ? "" :
                    "pass visible_only:true to return ONLY what is on screen (on a long/recycling list most nodes are " +
                    "offscreen rows that eat the budget before the visible ones are reached — scroll and re-read to see more), or ") +
                "pass filter:{label:\"…\"} or filter:{type:\"button\"} to return only matching nodes (with their ancestor path), " +
                "or max_depth:3-4 for just the top structure. " + hint
        } else if filter.active {
            hint = "Filtered view: only nodes matching your filter (plus their ancestors) are shown. " +
                "Remove the filter for the full tree. " + hint
        }

        // State the active limits every time, not only when they bite. A caller
        // that doesn't know a cap applied will read a partial tree as the whole
        // page and conclude an element is absent when it was merely cut off.
        let usedDefaults = cmd.maxDepth == nil && cmd.maxElements == nil
        let depthLabel = maxDepth == Int.max ? "unlimited" : String(maxDepth)
        let effectiveMaxChildren = cmd.maxChildren.map { max(1, min($0, 5000)) } ?? Self.maxChildrenPerNode
        let limits = "Limits on THIS response: max_depth=\(depthLabel), max_children=\(effectiveMaxChildren), " +
            "max_elements=\(maxElements)\(usedDefaults ? " (defaults)" : " (as requested)"). " +
            "Deeper or wider reads are available — pass max_depth / max_elements — but cost scales with the " +
            "number of nodes actually walked: on a feed that has been scrolled for a while, offscreen rows " +
            "accumulate and a full read can take seconds and may exceed the 6s call limit. Cheaper first " +
            "moves: filter:{label:\"…\"}/{type:\"button\"} to fetch only what you need, or relaunch the app " +
            "to drop accumulated rows."
        hint = limits + " " + hint

        var result: [String: JSONValue] = [
            "format": .string("text"),
            "source": .string(body),
            "truncated": .bool(truncated),
            "total_returned": .int(count),
            "coordinate_space": .string("points"),
            "hint": .string(hint),
            // Which fetch ran. The bounded path can drop out silently if the
            // private API shifts again, and the only symptom would be the old
            // multi-second timings — so make it observable.
            "snapshot_path": .string(usedBoundedSnapshot ? "bounded" : "full"),
            // Where the time actually went. fetch_ms is the AX round trip into
            // the target app; render_ms is walking that tree and building the
            // text. They have different fixes — a slow fetch means the app's
            // hierarchy is huge (cap depth/children, or relaunch to drop
            // accumulated rows), a slow render means too many nodes are being
            // written out (filter, or visible_only).
            "timing": .object([
                "fetch_ms": .int(Int(fetchMs.rounded())),
                "render_ms": .int(Int(renderMs.rounded())),
            ]),
            "max_children_used": .int(childrenUsed),
            // Always reported, not just when the fallback fires: without it there
            // is no way to tell "the trigger decided the tree was fine" from "the
            // trigger never ran", which is exactly the ambiguity that hid a bug here.
            "ax_coverage": .double((visibleLabelledCoverage(body) * 100).rounded() / 100),
            // Which channel produced the tree. NOT named "source": that key is
            // already the tree TEXT in this same dictionary, and a duplicate key
            // in a Swift dictionary literal is a runtime trap — it crashed the
            // runner outright (EXC_BREAKPOINT in Dictionary.init(dictionaryLiteral:))
            // on the first page_source after the tag was added.
            "source_channel": .string("ax"),
        ]
        if usedBoundedSnapshot {
            iCTRLUITests.logBuffer.append(
                "🌲 page_source fetch=\(Int(fetchMs.rounded()))ms render=\(Int(renderMs.rounded()))ms "
                + "nodes=\(count)\(boundedTruncated ? " TRUNCATED" : "")"
                + " mc=\(childrenUsed)\(ladderSteps.count > 1 ? "[\(ladderSteps.joined(separator: " "))]" : "")"
                + (cmd.visibleOnly == true ? " visible_only" : "")
                + (filter.active ? " filtered" : ""))
        }

        // The one failure mode this whole path can still hit, and the only one
        // that is silent: a long list whose rows are ALL above the viewport in
        // the returned tree. Measured on a scrolled WeChat chat list — the 2000
        // element cap is consumed by offscreen rows before the visible ones are
        // reached, so the caller gets a healthy-looking tree with zero on-screen
        // rows, `truncated` false, and no error. Say so explicitly, because the
        // natural (wrong) conclusion is "the screen is empty".
        if usedBoundedSnapshot, cmd.visibleOnly != true,
           let probe = Self.underFetchProbe(body, requested: childrenUsed),
           probe.lastBottom < 0 {
            let rowsShort = probe.rowHeight > 0 ? abs(probe.lastBottom) / probe.rowHeight : 0
            result["viewport_warning"] = .string(
                "The list rows in this tree all sit ABOVE the screen (lowest row ends "
                + "\(abs(probe.lastBottom))pt above the top"
                + (rowsShort > 0 ? ", roughly \(rowsShort) rows short" : "") + "). "
                + "The rows you can actually see were not reached"
                + (probe.saturated
                    ? " — the container returned everything it has, so raising max_children will NOT help; "
                      + "the element cap is what ran out. Raise max_elements, or pass visible_only:true "
                      + "(it keeps on-screen rows within the same budget)."
                    : " — raise max_children.")
                + " Do NOT conclude the screen is empty from this tree."
                + " Fastest recovery: screen_text — it OCRs the screenshot, which does not go"
                + " through the accessibility channel at all. Measured on this exact case it read"
                + " ~5x more on-screen text than the tree, in ~700ms.")
        }

        // Same advice, one step earlier: a tree that is technically fine but
        // nearly empty on a page the user can see content on. Measured: a
        // scrolled WeChat list yields 6 visible labels via the tree vs 35 via
        // OCR. Without this a caller reasonably concludes the screen is bare.
        if usedBoundedSnapshot, result["viewport_warning"] == nil, count > 0 {
            let visibleLabeled = body.split(separator: "\n").filter {
                $0.contains(", label: '") || $0.contains(", value: '")
            }.count
            if visibleLabeled < 10, count > 50 {
                result["sparse_hint"] = .string(
                    "Only \(visibleLabeled) labelled nodes here despite \(count) nodes total — typical of a "
                    + "recycling list that keeps its rows out of the accessibility tree. If the screen looks "
                    + "fuller than this, call screen_text (OCR of the screenshot, ~700ms, bypasses accessibility).")
            }
        }
        // OCR fallback: only present when the accessibility tree came back with
        // nothing on screen. Same item shape as find_element/screen_text, each
        // tagged source:"ocr", so it can be used directly — tap{x:center_x,
        // y:center_y} — without a second code path.
        if let ocr = ocrFallback {
            result["ocr_items"] = .array(ocr.items)
            result["ocr_count"] = .int(ocr.items.count)
            result["ocr_timing"] = .object([
                "screenshot_ms": .int(Int(ocr.shotMs.rounded())),
                "ocr_ms": .int(Int(ocr.ocrMs.rounded())),
            ])
            let axCoverage = visibleLabelledCoverage(body)
            result["ocr_reason"] = .string(
                axCoverage < 0.05
                ? "The accessibility tree returned NO on-screen content, so the screen was read by OCR instead. "
                  + "Use ocr_items (coordinates are in points; tap{x:center_x,y:center_y}). "
                  + "They carry no `ref` and go stale on scroll, so act on them immediately."
                : "The tree covers only \(Int(axCoverage * 100))% of the content area — below the 15% bar, so the "
                  + "screen was ALSO read by OCR. Compare the two: the tree has real types and refs, OCR has "
                  + "labelled on-screen nodes, which is what the tree above describes. OCR is included as a "
                  + "cross-check — prefer the tree items, they have real types and support refs.")
        }
        if filter.active { result["filtered"] = .bool(true) }
        if let bid = inspectedBundleId {
            result["bundle_id"] = .string(bid)
            // Say it up front, while the caller is still deciding how to locate
            // things — otherwise they burn a find_element round trip discovering
            // the page simply isn't in this tree.
            if Self.webViewHostBundleIds.contains(bid) {
                result["warning"] = .string(
                    "This is a BROWSER. The tree below is browser chrome ONLY — web page content " +
                    "(links, buttons, text inside the page) is not exposed to the accessibility tree and is absent here. " +
                    "Do not expect find_element to match anything in the page. " +
                    "To act on the page: screenshot → locate the target visually → divide pixel coords by that " +
                    "response's `scale` → tap{x,y}."
                )
            }
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

    /// Default traversal bounds for page_source, reported back in every response
    /// so a caller can tell a capped read from a complete one.
    static let defaultMaxDepth = 40
    /// 100 cut every page of a scrolled X timeline (8 of 9 reads came back
    /// truncated), because a feed keeps hundreds of rendered rows under one
    /// container. 500 clears that; the cost is bounded by max_elements anyway.
    static let maxChildrenPerNode = 1000

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

        /// Same predicate, against one ALREADY-RENDERED line from the bounded
        /// fetch. The bounded path is ~2x faster than the protocol walk but hands
        /// back text, not snapshots — so a filter used to disable it entirely and
        /// pay full price to return FEWER nodes. Matching the rendered line keeps
        /// the fast path.
        ///
        /// Line shape (see ICTRLRenderNode): `<indent>Type, label: '…', value: '…', id: '…', {{x, y}, {w, h}}`
        /// Only the type name is positional; the rest are optional named parts.
        func matchesRenderedLine(_ line: String) -> Bool {
            let trimmed = line.drop { $0 == " " }
            let typeName = trimmed.prefix { $0 != "," }.lowercased()
            if let t = type, !typeName.contains(t.lowercased()) { return false }

            // Field extraction must not fall back to the whole line: a `type`
            // filter would then match the frame digits, and a `label` filter
            // would match an id it was never meant to see.
            func field(_ name: String) -> String {
                guard let r = line.range(of: ", \(name): '") else { return "" }
                let rest = line[r.upperBound...]
                guard let end = rest.range(of: "'") else { return "" }
                return String(rest[..<end.lowerBound])
            }
            let label = field("label")
            let value = field("value")
            let ident = field("id")

            if let l = self.label {
                if !(label + " " + value).lowercased().contains(l.lowercased()) { return false }
            }
            if let tx = self.text {
                if !(label + " " + value + " " + ident).lowercased().contains(tx.lowercased()) { return false }
            }
            return true
        }
    }

    /// Escalation ladder for the adaptive `max_children` fetch.
    ///
    /// Starts small because the measured distribution is strongly BIMODAL: across
    /// 20 apps x 2 screens, 38 of 40 samples had at most 36 direct children in
    /// their largest scrollable container (median 10) — WeChat's chat list was the
    /// lone outlier at 392. So a small first fetch satisfies almost everything,
    /// and only the outliers pay for a second round.
    ///
    /// The jumps are large because there is NO caching on the accessibility side:
    /// measured, fetching mc=400 costs the same (~600ms) whether or not mc=800
    /// was just fetched, and ascending/descending sweeps are symmetric. A refetch
    /// is therefore paid in full, which rules out cautious doubling — few, big
    /// steps beat many small ones.
    private static let childrenLadder = [50, 500, 1000, 2000]

    /// How many LABELLED nodes in this rendered tree actually intersect the
    /// screen — i.e. how much of it a caller could act on.
    ///
    /// This is the escalation trigger. Node count alone is useless here: a
    /// scrolled chat list happily returns 2000 nodes with zero on-screen rows,
    /// which reads as success everywhere except this measure.
    private func visibleLabelledCount(_ body: String) -> Int {
        let w = pointSize.width, h = pointSize.height
        // Chrome bands: the nav/status area and the tab bar. Their labels are
        // ALWAYS present (app title, search, tab names) whether or not any real
        // content came back, so counting them hides the exact failure this
        // measure exists to catch. Measured on a scrolled WeChat list: 8 visible
        // labels, every one chrome (微信/搜索/快捷操作/标签页栏/通讯录/发现),
        // zero conversations — while OCR read 34 texts including 10 real rows.
        //
        // The bounds are READ FROM THE TREE, not hardcoded: they differ per
        // device (screen height, presence of a home indicator) and per app
        // (measured: WeChat nav 62..106 + tab 780..873; RED tab 796..874 and no
        // nav bar at all). A fixed inset would be wrong on the next device or
        // the next app, and wrong silently.
        var topChrome = 0.0
        var bottomChrome = h
        for line in body.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            let isNav = t.hasPrefix("NavigationBar,") || t.hasPrefix("StatusBar,")
            let isTab = t.hasPrefix("TabBar,")
            guard isNav || isTab else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[3] > 0 else { continue }
            let (top, bottom) = (f[1], f[1] + f[3])
            // A bar spanning most of the screen is a container mislabelled as
            // chrome (Settings reports a Toolbar covering 0..874); honouring it
            // would exclude the whole screen and make this count always zero.
            guard f[3] < h * 0.4 else { continue }
            if isNav, bottom > topChrome, top < h * 0.3 { topChrome = bottom }
            if isTab, top < bottomChrome, bottom > h * 0.7 { bottomChrome = top }
        }
        var n = 0
        for line in body.split(separator: "\n") {
            guard line.contains(", label: '") || line.contains(", value: '") else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let nums = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard nums.count >= 4 else { continue }
            let (x, y, ww, hh) = (nums[0], nums[1], nums[2], nums[3])
            guard ww > 0, hh > 0, x < w, y < h, x + ww > 0, y + hh > 0 else { continue }
            // Count only what sits in the CONTENT band.
            let mid = y + hh / 2
            if mid > topChrome, mid < bottomChrome { n += 1 }
        }
        return n
    }

    /// Fraction of the CONTENT area (screen minus nav/tab chrome) covered by
    /// labelled nodes the caller could act on, 0...1.
    ///
    /// This is the fallback trigger, in preference to a node count: a count needs
    /// a threshold that is really a guess about screen size and list density,
    /// whereas a ratio is dimensionless and so travels across devices and apps
    /// unchanged. It also catches the case a count misses — a handful of labels
    /// that happen to exist while the body of the screen is empty.
    ///
    /// Overlapping rects are unioned on a coarse grid rather than summed: chat
    /// rows stack a cell, its title and its subtitle at the same place, and
    /// adding those areas up reports >100% coverage on a screen showing nothing.
    private func visibleLabelledCoverage(_ body: String) -> Double {
        let w = pointSize.width, h = pointSize.height
        var topChrome = 0.0
        var bottomChrome = h
        for line in body.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            let isNav = t.hasPrefix("NavigationBar,") || t.hasPrefix("StatusBar,")
            let isTab = t.hasPrefix("TabBar,")
            guard isNav || isTab else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[3] > 0, f[3] < h * 0.4 else { continue }
            if isNav, f[1] + f[3] > topChrome, f[1] < h * 0.3 { topChrome = f[1] + f[3] }
            if isTab, f[1] < bottomChrome, f[1] + f[3] > h * 0.7 { bottomChrome = f[1] }
        }
        let contentTop = topChrome, contentBottom = bottomChrome
        let contentH = max(contentBottom - contentTop, 1)

        // 16x32 occupancy grid over the content band — enough resolution to tell
        // "a few scattered labels" from "the screen is full", without the cost of
        // real polygon union.
        let cols = 16, rows = 32
        var grid = [Bool](repeating: false, count: cols * rows)
        for line in body.split(separator: "\n") {
            guard line.contains(", label: '") || line.contains(", value: '") else { continue }
            guard let r = line.range(of: "{{"),
                  let end = line.range(of: "}}", range: r.lowerBound..<line.endIndex) else { continue }
            let f = line[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard f.count >= 4, f[2] > 0, f[3] > 0 else { continue }
            // Skip labelled nodes that span (nearly) the whole screen. They are
            // containers — an Application/Window element carrying the app's name,
            // or a full-bleed backdrop — not things a caller can act on. Measured:
            // a scrolled WeChat list returns `微信` with h=874, and that single
            // node filled the entire occupancy grid, pinning coverage at 100% and
            // stopping the OCR fallback from EVER firing, on every app.
            guard f[2] < w * 0.98 || f[3] < h * 0.8 else { continue }
            let x0 = max(f[0], 0), y0 = max(f[1], contentTop)
            let x1 = min(f[0] + f[2], w), y1 = min(f[1] + f[3], contentBottom)
            guard x1 > x0, y1 > y0 else { continue }
            let c0 = Int((x0 / w) * Double(cols)), c1 = Int(((x1 / w) * Double(cols)).rounded(.up))
            let r0 = Int(((y0 - contentTop) / contentH) * Double(rows))
            let r1 = Int((((y1 - contentTop) / contentH) * Double(rows)).rounded(.up))
            for rr in max(r0, 0)..<min(max(r1, r0 + 1), rows) {
                for cc in max(c0, 0)..<min(max(c1, c0 + 1), cols) { grid[rr * cols + cc] = true }
            }
        }
        return Double(grid.filter { $0 }.count) / Double(cols * rows)
    }

    /// Worst (smallest) bottom edge among the direct children of any scrollable
    /// container, plus whether that container returned fewer children than asked.
    ///
    /// This is the under-fetch signal. It must be computed PER CONTAINER: a global
    /// "does anything reach the viewport" test always passes, because the nav bar,
    /// tab bar and window span the screen no matter how little list content came
    /// back — verified, it reported success even when zero rows were on screen.
    private static func underFetchProbe(_ body: String, requested: Int)
        -> (underFetched: Bool, saturated: Bool, lastBottom: Int, rowHeight: Int)? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count / 2 }
        func frame(_ s: String) -> (x: Int, y: Int, w: Int, h: Int)? {
            guard let r = s.range(of: "{{"), let end = s.range(of: "}}", range: r.lowerBound..<s.endIndex)
            else { return nil }
            let nums = s[r.lowerBound..<end.upperBound]
                .split(whereSeparator: { !"-0123456789".contains($0) })
                .compactMap { Int($0) }
            guard nums.count >= 4 else { return nil }
            return (nums[0], nums[1], nums[2], nums[3])
        }

        var result: (Bool, Bool, Int, Int)?
        for (i, line) in lines.enumerated() {
            let t = line.drop { $0 == " " }
            guard t.hasPrefix("Table,") || t.hasPrefix("CollectionView,") || t.hasPrefix("ScrollView,")
            else { continue }
            let depth = indent(line)
            var kids: [(x: Int, y: Int, w: Int, h: Int)] = []
            var j = i + 1
            while j < lines.count, indent(lines[j]) > depth {
                if indent(lines[j]) == depth + 1, let f = frame(lines[j]) { kids.append(f) }
                j += 1
            }
            // Containers with a couple of children are chrome, not a feed.
            guard kids.count >= 3 else { continue }
            let lastBottom = kids.map { $0.y + $0.h }.max() ?? 0
            let heights = kids.map { $0.h }.filter { $0 > 0 }.sorted()
            let rowH = heights.isEmpty ? 0 : heights[heights.count / 2]
            // Fewer children than requested means the container is exhausted —
            // asking for more cannot return more, so the ladder must stop.
            let saturated = kids.count < requested
            let under = lastBottom < 0
            if result == nil || lastBottom < result!.2 {
                result = (under, saturated, lastBottom, rowH)
            }
        }
        return result
    }

    /// Apply a filter to bounded-fetch output, preserving the ancestor path of
    /// every match so the result reads as a tree rather than a flat list — the
    /// same contract `renderSnapshotInto` provides on the protocol path.
    private static func filterRenderedTree(_ body: String, filter: SnapshotFilter) -> (text: String, count: Int) {
        guard filter.active else { return (body, body.isEmpty ? 0 : body.split(separator: "\n").count) }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var keep = [Bool](repeating: false, count: lines.count)

        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }

        for (i, line) in lines.enumerated() where filter.matchesRenderedLine(line) {
            keep[i] = true
            // Walk back up marking each strictly-shallower ancestor, so the
            // match keeps its context instead of appearing at the root.
            var need = indent(line)
            guard need > 0 else { continue }
            var j = i - 1
            while j >= 0, need > 0 {
                let ind = indent(lines[j])
                if ind < need { keep[j] = true; need = ind }
                j -= 1
            }
        }

        var out: [String] = []
        var matched = 0
        for (i, line) in lines.enumerated() where keep[i] {
            out.append(line)
            if filter.matchesRenderedLine(line) { matched += 1 }
        }
        // Count reports MATCHES, not emitted lines — ancestors are context, and
        // counting them would inflate "how many buttons are on screen".
        return (out.joined(separator: "\n"), matched)
    }

    /// Recursively render a snapshot subtree into `lines`. When a filter is
    /// active, a node is emitted only if it matches OR one of its descendants
    /// matches — so the ancestor path to every match is preserved and the tree
    /// stays readable. `globalCount` is shared across the whole traversal so the
    /// max_elements hard cap is honored regardless of subtree.
    @discardableResult
    private func renderSnapshotInto(_ s: XCUIElementSnapshot, depth: Int, maxDepth: Int,
                                    maxElements: Int, filter: SnapshotFilter,
                                    cullToViewport: Bool = false,
                                    viewportRect: CGRect = .null,
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

        // Mirror the bounded path's viewport culling so visible_only behaves the
        // same when the fast fetch falls back — otherwise the flag would silently
        // do nothing exactly on the pages that most need it.
        let selfVisible = !cullToViewport || {
            let fr = s.frame
            return fr.width > 0 && fr.height > 0 && fr.intersects(viewportRect)
        }()
        let selfMatches = (!filter.active || filter.matches(s)) && selfVisible
        var childLines: [String] = []
        var descendantMatched = false

        if depth < maxDepth {
            // Cap siblings per node as well as total depth: a single list can
            // hold hundreds of rendered rows, and walking all of them is what
            // makes a scrolled feed expensive. Reported in the response hint.
            //
            var childrenWalked = 0
            for child in s.children {
                if globalCount >= maxElements { truncated = true; break }
                if childrenWalked >= Self.maxChildrenPerNode { truncated = true; break }
                childrenWalked += 1
                var sub: [String] = []
                var subCount = 0
                let kept = renderSnapshotInto(child, depth: depth + 1, maxDepth: maxDepth,
                                              maxElements: maxElements, filter: filter,
                                              cullToViewport: cullToViewport, viewportRect: viewportRect,
                                              lines: &sub, localCount: &subCount,
                                              globalCount: &globalCount, truncated: &truncated,
                                              seenFrames: &seenFrames)
                if kept { childLines.append(contentsOf: sub); descendantMatched = true }
            }
        }

        // Skip emitting a duplicate leaf, but still surface children that are new.
        // With culling on, an invisible node survives only as the ancestor path
        // of a visible descendant — never on its own.
        let gate = cullToViewport ? (selfMatches || descendantMatched)
                                  : (!filter.active || selfMatches || descendantMatched)
        let keep = gate && (!isDup || descendantMatched)
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
            return (nil, JSONRPCError(
                code: -32602,
                message: "scroll_to_element requires 'element_id' (the label, value, or accessibility id to scroll to). " +
                    "Next: call page_source to read the available labels, then retry as " +
                    "scroll_to_element{element_id:\"<label>\", match:\"contains\"}. " +
                    "Full parameter list: GET /schema.",
                data: nil))
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

        let scrollBase = "No \(matchMode == "contains" ? "" : "exact ")match for '\(query)'" +
            (typeFilter.map { " of type '\($0)'" } ?? "") +
            " after \(actualSwipes) swipes \(direction)" +
            (reachedEnd ? " (reached the end of scrollable content)" : "")
        if foregroundIsWebViewHost() {
            return (nil, JSONRPCError(code: -32602, message: scrollBase + "." + Self.webViewAdvice, data: nil))
        }
        return (nil, JSONRPCError(
            code: -32602,
            message: scrollBase +
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
        // Cleared per call: a stale error from an earlier lookup must never be
        // reported against this one — and stale geometry from an earlier screen
        // must never aim this call's tap.
        lastLocateError = nil
        lastLocateSnapFrame = nil
        lastLocateSnapLabel = nil
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

        // Every .safeExists / .safeIsHittable below is a round-trip that XCTest
        // answers by walking the app's hierarchy, so each scales with tree size. On a
        // long-scrolled feed a single probe ran into seconds, and the old loop of
        // up to 10 of them turned one find_element into 69.8s — during which the
        // serial UI queue is blocked and every later request piles up behind it.
        // Bound the whole scan instead of trusting any single call to be quick.
        let liveQueryDeadline = nowMonotonic + Self.liveQueryBudget
        func firstHittable(_ query: XCUIElementQuery) -> (XCUIElement, Int)? {
            let first = query.element(boundBy: 0)
            guard first.safeExists else { return nil }
            if first.safeIsHittable { return (first, 0) }
            // Probe siblings only while budget remains; 3 is plenty in practice
            // (the wanted element is almost always the first or second match).
            for i in 1..<3 {
                if nowMonotonic >= liveQueryDeadline {
                    phases.append("live-budget-hit")
                    break
                }
                let el = query.element(boundBy: i)
                if !el.safeExists { break }
                if el.safeIsHittable { return (el, i) }
            }
            return (first, 0)   // exists but not hittable — caller decides
        }

        // The live-query "fast path" is only fast on a small tree. XCUIElementQuery
        // evaluates its predicate node-by-node across the IPC boundary while the
        // app walks its whole hierarchy, so it scales with tree size just like a
        // snapshot does — measured at 5245ms to find WeChat's search field, and
        // 69865ms on a long-scrolled X timeline. One snapshot of the same WeChat
        // screen costs ~4100ms and answers exact/id/contains together, so it is
        // tried first and the live query is kept only as the fallback.
        var s = nowMonotonic
        var snapshotAlreadyTried = false
        if !Self.preferLiveQueryFirst,
           Self.snapshotPrecheck(bundleId: bid, action: "find '\(query)'",
                                 retryWith: "find_element") == nil {
            snapshotAlreadyTried = true
            if let hit = locateViaSnapshot(query: query, matchMode: matchMode, target: target,
                                           q: q, appendPhase: { phases.append($0) }, lap: lap) {
                done("\(hit.2)")
                return (hit.0, hit.1, hit.3)
            }
            // A completed snapshot walk is authoritative: it saw every node and
            // the label was not among them, so the live query can only reach the
            // same verdict — at the cost of a full second traversal. Measured on
            // a scrolled X timeline: the snapshot answered in 4.6s, then the
            // redundant live query ran another 7.1s before hitting its budget.
            // Only skip it when the walk actually happened; if the snapshot
            // itself failed we learned nothing and still owe the live query.
            if !phases.contains("snapshot=failed") {
                done("✗no-match")
                return nil
            }
        }

        // Run the live query under a hard wall-clock cap. A single .safeExists on a
        // huge tree has been seen to take tens of seconds and cannot be
        // cancelled, so the work continues in the background — but we stop
        // waiting on it and fall through, which keeps the RPC inside its own
        // 6s watchdog instead of blocking the queue for a minute.
        // Boxed so the abandoned worker can keep writing safely after we stop
        // waiting: reading `liveHit` only once runWithTimeout reports success
        // means the two never touch it at the same time.
        final class HitBox { var value: (XCUIElement, Int)? }
        let box = HitBox()
        let liveDone = runWithTimeout(seconds: Self.liveQueryBudget) {
            box.value = firstHittable(q.matching(NSPredicate(format: "label == %@", query)))
        }
        lap("exact", from: s)
        if !liveDone { phases.append("exact=timeout") }
        if liveDone, let (el, idx) = box.value {
            let (best, bestIdx) = elevateToButton(match: el, matchIdx: idx, in: target, phases: &phases)
            done("→exact\(bestIdx == idx ? "" : "→button")")
            return (best, .exactLabel(query), bestIdx)
        }

        // The snapshot path is where a backgrounded app costs ~16s of blocked
        // serial queue, so refuse it up front — the same guard page_source has
        // had. The live query above needs no such check; it fails fast.
        if let err = Self.snapshotPrecheck(bundleId: bid, action: "find '\(query)'",
                                           retryWith: "find_element") {
            phases.append("precheck=refused")
            done("✗\(err.message.contains("background") ? "backgrounded" : "not-running")")
            lastLocateError = err
            return nil
        }

        // Only when the snapshot-first attempt above didn't already run. A miss
        // used to capture the tree twice (logged as snapshot=…ms … snapshot=…ms),
        // paying the most expensive step of the lookup a second time for nothing.
        if !snapshotAlreadyTried,
           let hit = locateViaSnapshot(query: query, matchMode: matchMode, target: target,
                                       q: q, appendPhase: { phases.append($0) }, lap: lap) {
            done("\(hit.2)")
            return (hit.0, hit.1, hit.3)
        }
        done("✗no-match")
        return nil
    }

    /// Whether to try the live XCUIElementQuery before the snapshot walk.
    ///
    /// Snapshot-first is the faster order on every screen measured (a live query
    /// took 5245ms to find WeChat's search field, 69865ms on a scrolled X
    /// timeline; one snapshot of the same WeChat screen is ~4100ms and answers
    /// exact/id/contains together). Promoting it once aborted the runner —
    /// snapshot() raises an NSException that `try?` cannot catch — so every call
    /// now goes through ForegroundApp.safeSnapshot, which catches it in Obj-C.
    /// Wall-clock cap on the live XCUIElementQuery stage of a lookup.
    ///
    /// 2.5s leaves room for the snapshot fallback to still finish inside the 6s
    /// RPC watchdog. Without a cap this stage measured 69.8s on a scrolled X
    /// timeline, blocking the serial UI queue for every request behind it.
    static let liveQueryBudget: TimeInterval = 2.5

    /// Flip to true to fall back to the old ordering without a code change.
    ///
    /// The two aborts this caused were never about XCTest: the crash report put
    /// swift_beginAccess -> fatalError directly under `lap`, i.e. `phases` was
    /// captured by that closure AND passed inout to the same call, so Swift
    /// trapped on overlapping exclusive access. Fixed by passing an appendPhase
    /// closure instead of the array.
    static let preferLiveQueryFirst = false

    /// Finds `query` by walking ONE snapshot, answering exact-label, identifier
    /// and substring matching in a single capture.
    ///
    /// A snapshot carries label, identifier, value, frame and elementType, which
    /// is everything these strategies need, so one capture answers all of them
    /// and the walk itself is ~20ms — versus a live query per strategy, each
    /// paying its own accessibility round-trip.
    /// `phases` is NOT taken inout: the caller's `lap` closure already captures
    /// and mutates that same array, so passing it inout as well opens two
    /// overlapping exclusive accesses and Swift traps at runtime
    /// (swift_beginAccess -> fatalError), killing the runner. Everything that
    /// needs to record a phase goes through `lap` / `appendPhase`.
    private func locateViaSnapshot(query: String, matchMode: String, target: XCUIApplication,
                                   q: XCUIElementQuery,
                                   appendPhase: (String) -> Void,
                                   lap: (String, TimeInterval) -> Void)
        -> (XCUIElement, ElementRef.Match, String, Int)? {
        let wantExact = Self.normalizeLabel(query)
        var s = nowMonotonic
        // Via the Obj-C wrapper: snapshot() throws an NSException that `try?`
        // cannot catch, which aborted the runner when this became the primary
        // path (SIGABRT on the first call, no phases logged).
        guard let root = ForegroundApp.safeSnapshot(ofElement: target) as? XCUIElementSnapshot else {
            lap("snapshot", s)
            appendPhase("snapshot=failed")   // distinguishes "couldn't look" from "looked, absent"
            return nil
        }
        lap("snapshot", s)

        // Depth-first walk, collecting the best candidate per strategy in one
        // pass. Ordering is preserved from the old sequential version: an exact
        // label beats an identifier, which beats a substring.
        s = nowMonotonic
        var exactSnap: XCUIElementSnapshot?
        var idSnap: XCUIElementSnapshot?
        var containsSnap: XCUIElementSnapshot?
        var stack: [XCUIElementSnapshot] = [root]
        var visited = 0
        var allNodes: [XCUIElementSnapshot] = []
        while let node = stack.popLast(), visited < 4000 {
            visited += 1
            allNodes.append(node)
            if exactSnap == nil, Self.normalizeLabel(node.label) == wantExact {
                exactSnap = node
                break   // exact wins immediately
            }
            if idSnap == nil, node.identifier == query {
                idSnap = node
            }
            if matchMode == "contains", containsSnap == nil {
                let hay = Self.normalizeLabel(node.label + " " + ((node.value as? String) ?? ""))
                if hay.localizedCaseInsensitiveContains(wantExact) { containsSnap = node }
            }
            stack.append(contentsOf: node.children)
        }
        appendPhase("walk=\(Int((nowMonotonic - s) * 1000))ms/\(visited)nodes")

        // Re-resolve the winning snapshot to a live XCUIElement. Elevation now
        // reuses `allNodes` instead of re-enumerating every button and cell.
        let ranked: [(XCUIElementSnapshot, ElementRef.Match, String)] = [
            exactSnap.map    { ($0, ElementRef.Match.exactLabel($0.label), "→snapshot-exact") },
            idSnap.map       { ($0, ElementRef.Match.identifier(query),    "→snapshot-id") },
            containsSnap.map { ($0, ElementRef.Match.exactLabel($0.label), "→snapshot-contains") },
        ].compactMap { $0 }

        s = nowMonotonic
        for (snap, match, hit) in ranked {
            guard let (live, idx) = resolveSnapshot(snap, match: match, in: q) else { continue }
            lap("resolve", s)
            // Local array, then hand the results to appendPhase: elevateToButton
            // needs an inout, and the caller's copy is already owned by `lap`.
            var elevatePhases: [String] = []
            let (best, bestIdx, finalSnap) = elevateToButton(match: live, matchIdx: idx, snapshot: snap,
                                                             allNodes: allNodes, phases: &elevatePhases)
            elevatePhases.forEach(appendPhase)
            // Geometry of the FINAL node (post-elevation), free to read — the
            // snapshot is already materialised. findAndTap uses this to skip
            // re-buying frame/label from the live element.
            lastLocateSnapFrame = finalSnap.frame
            lastLocateSnapLabel = finalSnap.label
            return (best, match, "\(hit)\(bestIdx == idx ? "" : "→button")", bestIdx)
        }
        lap("resolve", s)
        return nil
    }

    /// Turn a matched snapshot node back into a live, tappable XCUIElement.
    private func resolveSnapshot(_ snap: XCUIElementSnapshot, match: ElementRef.Match,
                                 in q: XCUIElementQuery) -> (XCUIElement, Int)? {
        // Prefer the identifier when that's what matched — it's more selective
        // than a label, which several nodes may share.
        let re: XCUIElement
        if case .identifier(let ident) = match {
            re = q.matching(identifier: ident).element(boundBy: 0)
        } else {
            re = q.matching(NSPredicate(format: "label == %@", snap.label)).element(boundBy: 0)
        }
        return re.safeExists ? (re, 0) : nil
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
        guard !Self.isIntrinsicallyTappable(match.elementType) else {
            phases.append("elevate=skip(\(match.elementType.rawValue))")
            return (match, matchIdx)
        }
        let matchFrame = match.frame
        // Empty-frame elements can't be usefully compared for containment.
        if matchFrame.width < 1 || matchFrame.height < 1 { return (match, matchIdx) }
        let centre = CGPoint(x: matchFrame.midX, y: matchFrame.midY)

        // Consider both buttons AND cells as elevation targets. SwiftUI
        // `List(selection:)` rows are exposed as .cell, not .button; a
        // staticText leaf inside such a row needs to be elevated to the
        // enclosing cell for XCUIElement.tap to hit the selection region.
        var candidates: [XCUIElement] = []
        candidates.append(contentsOf: target.buttons.allElementsBoundByAccessibilityElement)
        candidates.append(contentsOf: target.cells.allElementsBoundByAccessibilityElement)
        var best: (XCUIElement, CGRect)?
        for c in candidates {
            let f = c.frame
            if f.width < 1 || f.height < 1 { continue }
            if !f.contains(centre) { continue }
            // Prefer the tightest fit: smallest area that still contains the match.
            let area = f.width * f.height
            if let (_, current) = best, area >= current.width * current.height { continue }
            best = (c, f)
        }
        phases.append("elevate=\(Int((nowMonotonic - t0) * 1000))ms/\(candidates.count)cands")
        if let (bestEl, _) = best, bestEl.safeIsHittable {
            return (bestEl, matchIdx)
        }
        return (match, matchIdx)
    }

    /// Snapshot-based elevation: same tightest-containing-ancestor rule as the
    /// live variant, but the candidates come from the tree we already walked.
    ///
    /// The live version calls `allElementsBoundByAccessibilityElement` on both
    /// `buttons` and `cells` and then reads `.frame` on every result — two full
    /// enumerations plus a round-trip per candidate, paid on the SUCCESS path. The
    /// snapshot already carries frame and elementType for every node, so the same
    /// decision costs a pass over an in-memory array.
    /// Also returns the snapshot of the node the caller should treat as FINAL —
    /// the elevated ancestor's when elevation succeeded, the original match's
    /// otherwise. Callers that reuse snapshot geometry must take it from here:
    /// after elevation the tap target is the Button/Cell, and using the inner
    /// match's frame would aim at the row instead of its control.
    private func elevateToButton(match: XCUIElement, matchIdx: Int,
                                 snapshot snap: XCUIElementSnapshot,
                                 allNodes: [XCUIElementSnapshot],
                                 phases: inout [String]) -> (XCUIElement, Int, XCUIElementSnapshot) {
        let t0 = nowMonotonic
        guard !Self.isIntrinsicallyTappable(snap.elementType) else {
            phases.append("elevate=skip(\(snap.elementType.rawValue))")
            return (match, matchIdx, snap)
        }
        let matchFrame = snap.frame
        if matchFrame.width < 1 || matchFrame.height < 1 { return (match, matchIdx, snap) }
        let centre = CGPoint(x: matchFrame.midX, y: matchFrame.midY)

        var best: XCUIElementSnapshot?
        var bestArea = CGFloat.greatestFiniteMagnitude
        var considered = 0
        for node in allNodes {
            switch node.elementType {
            case .button, .cell: break
            default: continue
            }
            considered += 1
            let f = node.frame
            if f.width < 1 || f.height < 1 { continue }
            if !f.contains(centre) { continue }
            let area = f.width * f.height
            if area >= bestArea { continue }
            best = node
            bestArea = area
        }
        phases.append("elevate=\(Int((nowMonotonic - t0) * 1000))ms/\(considered)cands")

        // Re-resolve the chosen ancestor to a live element. Falling back to the
        // original match keeps this best-effort: a failed elevation must never
        // turn a found element into a miss.
        guard let bestSnap = best else { return (match, matchIdx, snap) }
        let query = bestSnap.elementType == .cell ? app.cells : app.buttons
        let live = bestSnap.identifier.isEmpty
            ? query.matching(NSPredicate(format: "label == %@", bestSnap.label)).element(boundBy: 0)
            : query.matching(identifier: bestSnap.identifier).element(boundBy: 0)
        if live.safeExists, live.safeIsHittable { return (live, matchIdx, bestSnap) }
        return (match, matchIdx, snap)
    }

    /// Element kinds that already dispatch their own handler on tap, so a
    /// label match landing on one needs no elevation.
    private static func isIntrinsicallyTappable(_ type: XCUIElement.ElementType) -> Bool {
        switch type {
        case .button, .cell, .switch, .toggle, .radioButton, .checkBox,
             .menuButton, .menuItem, .key, .link, .searchField, .textField, .textView:
            return true
        default:
            return false
        }
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

    /// OCR the screen and return text boxes in the SAME shape find_element uses.
    ///
    /// Exists for one failure mode the accessibility path cannot recover from: a
    /// long recycling list whose on-screen rows never make it into the tree. On a
    /// scrolled WeChat chat list every route — default, max_children up to 1000,
    /// even a saturated container — returned ZERO on-screen cells, because the
    /// element budget is spent on offscreen rows before the visible ones are
    /// reached. Screenshots do not go through the accessibility channel at all,
    /// so they still work when that channel gives nothing useful.
    ///
    /// Deliberately mirrors find_element's keys (x/y/width/height/center_x/
    /// center_y/label/element_type) so a caller can feed a hit straight into
    /// tap{x,y} without a second code path.
    ///
    /// What it CANNOT give you: `ref` (so no scroll/animation-stable handle),
    /// `identifier`, or the real element type — everything here is typed
    /// "OCRText". It also only sees rendered text: icon-only buttons and image
    /// content are invisible to it, which is exactly where accessibility labels
    /// are most valuable. Treat it as a fallback, not a replacement.
    /// Convert Vision results into the shared item shape.
    ///
    /// Vision's box is normalised with the ORIGIN AT BOTTOM-LEFT while iOS points
    /// are top-left, so y is flipped here. Getting that wrong is quietly awful:
    /// every coordinate still looks plausible, but taps land mirrored about the
    /// middle of the screen.
    private func ocrItems(from request: VNRecognizeTextRequest, minConfidence: Float) -> [JSONValue] {
        let frame = pointSize
        var items: [JSONValue] = []
        for obs in (request.results ?? []) {
            guard let top = obs.topCandidates(1).first, top.confidence >= minConfidence else { continue }
            let b = obs.boundingBox
            let x = b.minX * frame.width
            let w = b.width * frame.width
            let h = b.height * frame.height
            let y = (1 - b.maxY) * frame.height
            items.append(.object([
                "label": .string(top.string),
                "confidence": .double(Double(top.confidence)),
                "x": .double(x.rounded()), "y": .double(y.rounded()),
                "width": .double(w.rounded()), "height": .double(h.rounded()),
                "center_x": .double((x + w / 2).rounded()),
                "center_y": .double((y + h / 2).rounded()),
                "element_type": .string("OCRText"),
                "source": .string("ocr"),
                "is_text_input": .bool(false), "exists": .bool(true),
            ]))
        }
        return items
    }

    /// Run OCR and return the items plus timings. Shared by `screen_text` and by
    /// page_source's automatic fallback, so both produce identical item shapes.
    private func runOCR(query: String?, fast: Bool, minConfidence: Float)
        -> (items: [JSONValue], shotMs: Double, ocrMs: Double)? {
        let frame = pointSize
        var image: UIImage?
        let shotStart = nowMonotonic
        _ = ObjCException.catching { image = XCUIScreen.main.screenshot().image }
        let shotMs = (nowMonotonic - shotStart) * 1000
        guard let cg = image?.cgImage else { return nil }

        let ocrStart = nowMonotonic
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        if let q = query, !q.isEmpty { request.customWords = [q] }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let ocrMs = (nowMonotonic - ocrStart) * 1000

        var items: [JSONValue] = []
        for obs in (request.results ?? []) {
            guard let top = obs.topCandidates(1).first, top.confidence >= minConfidence else { continue }
            // Vision's box is normalised with the ORIGIN AT BOTTOM-LEFT; iOS points
            // are top-left. Flipping y is what makes these coordinates tappable —
            // get it wrong and every tap lands mirrored about the middle.
            let b = obs.boundingBox
            let x = b.minX * frame.width
            let w = b.width * frame.width
            let h = b.height * frame.height
            let y = (1 - b.maxY) * frame.height
            if let q = query, !q.isEmpty, !top.string.localizedCaseInsensitiveContains(q) { continue }
            items.append(.object([
                "label": .string(top.string),
                "confidence": .double(Double(top.confidence)),
                "x": .double(x.rounded()), "y": .double(y.rounded()),
                "width": .double(w.rounded()), "height": .double(h.rounded()),
                "center_x": .double((x + w / 2).rounded()),
                "center_y": .double((y + h / 2).rounded()),
                "element_type": .string("OCRText"),
                // Which channel produced this item. Both sources use identical
                // keys so a caller can merge them into one list and still tap
                // either, but they are NOT interchangeable: "ax" items carry a
                // usable element_type and can be re-located by ref, "ocr" items
                // are screen text at a moment in time and go stale on scroll.
                "source": .string("ocr"),
                "is_text_input": .bool(false), "exists": .bool(true),
            ]))
        }
        return (items, shotMs, ocrMs)
    }

    private func screenText(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        let frame = pointSize
        var image: UIImage?
        let shotStart = nowMonotonic
        // Same capture as `screenshot`: XCUIScreen never blocks on quiescence,
        // and crucially does NOT go through the accessibility channel — which is
        // the whole reason this method can succeed when page_source cannot.
        _ = ObjCException.catching { image = XCUIScreen.main.screenshot().image }
        let shotMs = (nowMonotonic - shotStart) * 1000
        guard let cg = image?.cgImage else {
            return (nil, .serverError("Could not capture the screen for OCR."))
        }

        let ocrStart = nowMonotonic
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (cmd.matchMode == "fast") ? .fast : .accurate
        request.usesLanguageCorrection = false
        // Chinese first: the lists this exists for are Chinese apps, and Vision
        // weights by order. Latin stays in so mixed UI still reads.
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        if let q = cmd.elementId, !q.isEmpty { request.customWords = [q] }

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (nil, .serverError("OCR failed: \(error.localizedDescription)"))
        }
        let ocrMs = (nowMonotonic - ocrStart) * 1000

        let minConf = Float(cmd.scale ?? 0.3)
        var items: [JSONValue] = []
        for obs in (request.results ?? []) {
            guard let top = obs.topCandidates(1).first, top.confidence >= minConf else { continue }
            // Vision's box is normalised with the ORIGIN AT BOTTOM-LEFT; iOS points
            // are top-left. Flipping y is what makes these coordinates tappable —
            // get it wrong and every tap lands mirrored about the middle.
            let b = obs.boundingBox
            let x = b.minX * frame.width
            let w = b.width * frame.width
            let h = b.height * frame.height
            let y = (1 - b.maxY) * frame.height
            if let q = cmd.elementId, !q.isEmpty,
               !top.string.localizedCaseInsensitiveContains(q) { continue }
            items.append(.object([
                "label": .string(top.string),
                "confidence": .double(Double(top.confidence)),
                "x": .double(x.rounded()),
                "y": .double(y.rounded()),
                "width": .double(w.rounded()),
                "height": .double(h.rounded()),
                "center_x": .double((x + w / 2).rounded()),
                "center_y": .double((y + h / 2).rounded()),
                "element_type": .string("OCRText"),
                "source": .string("ocr"),
                "is_text_input": .bool(false),
                "exists": .bool(true),
            ]))
        }

        return ([
            "count": .int(items.count),
            "items": .array(items),
            "coordinate_space": .string("points"),
            "timing": .object([
                "screenshot_ms": .int(Int(shotMs.rounded())),
                "ocr_ms": .int(Int(ocrMs.rounded())),
            ]),
            "hint": .string(
                "OCR of what is RENDERED on screen — independent of the accessibility tree, "
                + "so it still works when page_source returns no on-screen rows. "
                + "Tap a result with tap{x:center_x, y:center_y} (already in points). "
                + "Limits: no `ref` (coordinates go stale on scroll — act immediately), no identifier, "
                + "and element_type is always 'OCRText', so you cannot tell a button from a label. "
                + "Text-only: icon buttons and images are invisible here. "
                + "Prefer find_element when the accessibility tree has the element."),
        ], nil)
    }

    private func findElementInfo(_ cmd: ActionCommand) -> ([String: JSONValue]?, JSONRPCError?) {
        guard let elementId = cmd.elementId else {
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_element requires 'element_id' (the accessibility label or identifier to search for). " +
                    "'element_type' alone is only a filter and cannot select an element by itself. " +
                    "Next: call page_source to read the visible labels, then retry as " +
                    "find_element{element_id:\"<label>\", element_type:\"textfield\", match:\"contains\"}. " +
                    "Full parameter list: GET /schema.",
                data: nil))
        }

        let matchMode = (cmd.matchMode ?? "exact").lowercased()
        guard let (element, match, index) = locateElement(query: elementId, type: cmd.elementType,
                                                          bundleId: cmd.bundleId, matchMode: matchMode) else {
            if let err = lastLocateError { return (nil, err) }
            let base = "No element matching label/id '\(elementId)'" +
                (cmd.elementType.map { " of type '\($0)'" } ?? "")
            if foregroundIsWebViewHost() {
                return (nil, JSONRPCError(code: -32602, message: base + "." + Self.webViewAdvice, data: nil))
            }
            return (nil, JSONRPCError(
                code: -32602,
                message: base +
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
            "hittable": .bool(element.safeIsHittable),
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
                "This is a \(typeName), NOT a text field. If you're trying to type/search: tap it to open the search page, wait ~1s for it to load and the keyboard to appear, then locate the REAL input field with find_element{element_id:\"<its placeholder text>\", element_type:\"textfield\", match:\"contains\"} before typing. (element_id is required — element_type alone only filters.)"
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
            if let err = lastLocateError { return (nil, err) }
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_and_tap: no element matching '\(elementId)'\(cmd.elementType.map { " of type '\($0)'" } ?? ""). Try match:'contains', or a different label from page_source.",
                data: nil
            ))
        }
        // fast:false — the original behaviour, kept as the escape hatch this
        // method historically existed for: native XCUIElement.tap() resolves the
        // element at hit time and works on SwiftUI Lists, where a synthesized
        // event reports success but the tap never lands (so the automatic
        // fallback below cannot catch it). Slow — quiescence waits on both
        // sides — but reliable.
        if cmd.fast == false {
            let f = element.frame
            let label = element.label
            guard element.safeIsHittable else {
                return (nil, JSONRPCError(
                    code: -32602,
                    message: "find_and_tap: element '\(elementId)' exists but is not hittable (off-screen, covered, or zero-size). Scroll it into view (scroll_to_element).",
                    data: ["x": .double(f.midX), "y": .double(f.midY)]
                ))
            }
            element.tap()
            return ([
                "message": .string("find_and_tap '\(label.isEmpty ? elementId : label)' via native XCUIElement.tap() (fast:false)"),
                "matched": .string(String(describing: match)),
                "frame": .object([
                    "x": .double(f.origin.x), "y": .double(f.origin.y),
                    "w": .double(f.width),    "h": .double(f.height),
                ]),
            ], nil)
        }

        // Phase-timed tail, two round trips instead of three. The 热榜 incident
        // put 9.3s of a 14.9s call here: frame + label + isHittable, each
        // re-running the live query (~3s apiece on an 856-node tree). The live
        // frame read stays — it is the existence check (throws if the element
        // vanished) and the tap aims at it, exactly as before. isHittable stays —
        // covering does NOT move a frame, so no probe can replace it. The label
        // read is gone: it only decorates the reply text, and locate's snapshot
        // already carries it. Comparing live vs snapshot frame is logged as
        // stable/drift telemetry — real-world drift rates are what will tell us
        // whether the frame read itself can ever be safely dropped.
        var tail: [String] = []
        var ts = nowMonotonic
        let f = element.frame
        tail.append("frame=\(Int((nowMonotonic - ts) * 1000))ms")
        if let sf = lastLocateSnapFrame {
            let stable = abs(sf.midX - f.midX) <= 2 && abs(sf.midY - f.midY) <= 2
            tail.append(stable ? "stable" : "drift(\(Int(sf.midX)),\(Int(sf.midY))→\(Int(f.midX)),\(Int(f.midY)))")
        } else {
            tail.append("no-snap")
        }
        // Cosmetic only — never worth a live round trip.
        let label = lastLocateSnapLabel ?? ""

        ts = nowMonotonic
        let hittable = element.safeIsHittable
        tail.append("hittable=\(Int((nowMonotonic - ts) * 1000))ms")

        guard hittable else {
            iCTRLUITests.logBuffer.append("🎯 find_and_tap tail [\(tail.joined(separator: " "))] ✗not-hittable")
            return (nil, JSONRPCError(
                code: -32602,
                message: "find_and_tap: element '\(elementId)' exists but is not hittable (off-screen, covered, or zero-size). Scroll it into view (scroll_to_element).",
                data: ["x": .double(f.midX), "y": .double(f.midY)]
            ))
        }

        // Synthesized tap at the element's own centre, same as tap(ref:) does.
        // XCUIElement.tap() waits for quiescence and post-event settling, which
        // measured ~7.6s here — the single most expensive part of find_and_tap,
        // costing more than locating the element. Fall back to the native tap
        // when synthesis fails, since that path still works on SwiftUI Lists
        // where synthesized events don't land.
        let (cx, cy) = humanizedPoint(in: f)
        ts = nowMonotonic
        let synth = fastHandler.fastTap(x: cx, y: cy)
        let usedNative = synth.1 != nil
        if usedNative { element.tap() }
        tail.append("tap=\(Int((nowMonotonic - ts) * 1000))ms\(usedNative ? "(native)" : "")")
        iCTRLUITests.logBuffer.append("🎯 find_and_tap tail [\(tail.joined(separator: " "))]")
        return ([
            "message": .string("find_and_tap '\(label.isEmpty ? elementId : label)' via " +
                               (usedNative ? "native XCUIElement.tap()" : "synthesized tap at (\(Int(cx)),\(Int(cy)))")),
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
            if let err = lastLocateError { return (nil, err) }
            return (nil, JSONRPCError(
                code: -32602,
                message: "No element matching '\(elementId)'\(cmd.elementType.map { " of type '\($0)'" } ?? ""). " +
                    "The label may differ from on-screen text (check page_source), or the element needs scrolling into view (use scroll_to_element). Try match:'contains', or fall back to screenshot + coordinate tap.",
                data: nil
            ))
        }
        guard element.safeIsHittable else {
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
