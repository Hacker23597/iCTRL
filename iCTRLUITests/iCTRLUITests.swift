import XCTest
import UserNotifications
import UIKit

final class iCTRLUITests: XCTestCase, UNUserNotificationCenterDelegate {
    private var server: JSONRPCServer?
    private var app: XCUIApplication!
    private var actionHandler: ActionHandler?
    private var pendingAuthCompletions: [String: (Bool) -> Void] = [:]
    private let authLock = NSLock()

    static let authCategoryID = "AUTH_REQUEST"
    static let allowActionID = "AUTH_ALLOW"
    static let denyActionID = "AUTH_DENY"

    static let serverReadyCategoryID = "SERVER_READY"
    static let serverRemoteCategoryID = "SERVER_REMOTE"
    static let serverStoppedCategoryID = "SERVER_STOPPED"
    static let enableRemoteActionID = "ENABLE_REMOTE"
    static let disableRemoteActionID = "DISABLE_REMOTE"
    static let stopServerActionID = "STOP_SERVER"
    static let copyLogsActionID = "COPY_LOGS"

    static let logBuffer = LogBuffer(capacity: 1000)

    /// Persisted preference key. Defaults to false (localhost-only) on a fresh install.
    static let allowRemoteAccessKey = "allowRemoteAccess"

    private var remoteAccessEnabled = false
    private var keepRunning = true

    /// Reads the persisted remote-access preference. Absent key → false (local only).
    private static var persistedRemoteAccess: Bool {
        get { UserDefaults.standard.bool(forKey: allowRemoteAccessKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowRemoteAccessKey) }
    }

    /// Persisted listen port. Absent key → 8200.
    private static var persistedPort: UInt16 {
        get {
            let v = UserDefaults.standard.integer(forKey: "serverPort")
            return (v > 0 && v <= 65535) ? UInt16(v) : 8200
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "serverPort") }
    }

    override func setUpWithError() throws {
        // Make the test "failure-proof" — like WebDriverAgent's FBFailureProofTestCase.
        // A hung/slow XCUITest call (tap/snapshot on an animating page) makes XCTest
        // record a failure and tear the test down, which kills the server. We keep
        // running through failures and swallow the failure reporting so XCTest never
        // decides to stop the long-running server test.
        continueAfterFailure = true
        // Don't halt when XCTest signals control interruptions (see appium#13949).
        if responds(to: Selector(("setShouldSetShouldHaltWhenReceivesControl:"))) {
            setValue(false, forKey: "shouldSetShouldHaltWhenReceivesControl")
        }
        if responds(to: Selector(("setShouldHaltWhenReceivesControl:"))) {
            setValue(false, forKey: "shouldHaltWhenReceivesControl")
        }

        app = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.activate()

        URLSchemeHandler.installURLHandler()
        setupNotifications()
    }

    /// Swallow XCTest failure reports so a slow/hung interaction can't tear the
    /// test (and the server) down. (WebDriverAgent overrides the same path.)
    override func record(_ issue: XCTIssue) {
        Self.logBuffer.append("⚠️ XCTest issue swallowed: \(issue.compactDescription.prefix(120))")
        // Intentionally NOT calling super — do not propagate the failure.
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        actionHandler = nil
    }

    func testStartServer() throws {
        // Tell the bootstrap watchdog the test actually began, so it won't re-kick
        // runTestsInBackground: (the watchdog covers the case where the first-launch
        // passcode prompt interrupted the XCTest bootstrap).
        EarlyURLHook.markTestStarted()

        // Prune old daily log files and note where logs are persisted.
        Self.logBuffer.pruneOldLogFiles()
        if let dir = Self.logBuffer.logDirectoryPath {
            Self.logBuffer.append("🗂 Logs persist to \(dir)/ictrl-YYYY-MM-DD.log")
        }

        actionHandler = ActionHandler(app: app)

        // Restore persisted preferences (fresh install → local only, port 8200)
        remoteAccessEnabled = Self.persistedRemoteAccess
        let port = Self.persistedPort
        server = JSONRPCServer(port: port, localOnly: !remoteAccessEnabled)

        // Wire up auth: send notification instead of auto-approve
        AuthManager.shared.setAutoApprove(false)
        AuthManager.shared.delegate = self

        if let s = server { configureServerCallbacks(s) }

        do {
            try server?.start()
            if remoteAccessEnabled {
                let address = getDeviceAddress()
                Self.logBuffer.append("🌐 Server started on \(address):8200 (remote access)")
                sendNotification(
                    title: "🟢 iCTRL Server Ready",
                    body: "Running on \(address):8200 (remote access)\nLong press to Disable Remote or Stop Server",
                    category: Self.serverRemoteCategoryID
                )
            } else {
                Self.logBuffer.append("🔒 Server started on 127.0.0.1:8200 (local only)")
                sendNotification(
                    title: "🟢 iCTRL Server Ready",
                    body: "Running on 127.0.0.1:8200 (local only)\nLong press for Remote Access or Stop Server",
                    category: Self.serverReadyCategoryID
                )
            }
        } catch {
            Self.logBuffer.append("🔴 Failed to start server: \(error)")
            sendNotification(
                title: "🔴 iCTRL Server Failed",
                body: error.localizedDescription
            )
        }

        keepRunning = true
        wireServerStateChange()

        // If launched via ictrl://start?callback=..., jump back to the caller now.
        handlePendingCallbackIfAny()

        let runLoop = RunLoop.current
        while keepRunning {
            autoreleasepool {
                // Short slice so main-queue work (the main.sync from the RPC queue)
                // and pending ictrl:// callbacks are serviced promptly. The runloop
                // also wakes early on dispatch, so this mainly bounds callback polling.
                runLoop.run(until: Date(timeIntervalSinceNow: 0.2))
                // A URL may also arrive after startup (app already running).
                handlePendingCallbackIfAny()
            }
        }
    }

    // MARK: - URL Scheme Callback

    /// Drain any pending ictrl:// URLs and, for each start URL carrying a
    /// callback, jump back to the caller with the server status/address.
    private func handlePendingCallbackIfAny() {
        for url in URLSchemeHandler.shared.takeAllPendingURLs() {
            handleOneURL(url)
        }
    }

    private func handleOneURL(_ url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []

        // Only the "start" host triggers a callback jump; others are ignored.
        let host = url.host?.lowercased()
        guard host == "start" || host == nil else {
            Self.logBuffer.append("🔗 Ignored ictrl:// host: \(host ?? "")")
            return
        }

        guard let callbackRaw = items.first(where: { $0.name == "callback" })?.value,
              !callbackRaw.isEmpty,
              let callbackURL = Self.normalizeCallback(callbackRaw) else {
            Self.logBuffer.append("🔗 ictrl://start with no callback — server is running")
            return
        }

        // The server starts asynchronously (and a passcode prompt may have delayed
        // everything). Wait — briefly — for it to actually be listening before we
        // report status, so we don't hand the caller a false "failed".
        let deadline = Date().addingTimeInterval(8)
        while !(server?.isRunning ?? false) && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }

        let running = server?.isRunning ?? false
        let address = remoteAccessEnabled ? "\(getDeviceAddress()):\(server?.port ?? 8200)"
                                          : "127.0.0.1:\(server?.port ?? 8200)"
        let status = running ? "ready" : "failed"

        // Append status + address to the callback URL.
        var cb = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        var q = cb?.queryItems ?? []
        q.append(URLQueryItem(name: "status", value: status))
        q.append(URLQueryItem(name: "address", value: address))
        cb?.queryItems = q

        guard let finalURL = cb?.url else {
            Self.logBuffer.append("🔗 Failed to build callback URL")
            return
        }

        Self.logBuffer.append("🔙 Callback → \(callbackURL.scheme ?? "")://…?status=\(status)")
        openCallback(finalURL, attempt: 1)
    }

    /// Accept a callback either as a full URL ("minis://home") or as a bare scheme
    /// ("minis" → "minis://"), so callers don't have to URL-encode a scheme.
    static func normalizeCallback(_ raw: String) -> URL? {
        if let u = URL(string: raw), u.scheme != nil {
            return u
        }
        // No scheme separator — treat the whole thing as a scheme name.
        let scheme = raw.hasSuffix("://") ? String(raw.dropLast(3)) : raw
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." })
        else { return nil }
        return URL(string: "\(scheme)://")
    }

    /// Open the callback URL. From inside the XCTest runner, UIApplication.open is
    /// unreliable (it returns false), so we open via LSApplicationWorkspace
    /// (ForegroundApp.openURL) — the same private path that reliably launches
    /// apps from the runner. UIApplication.open is kept as a last-resort fallback.
    private func openCallback(_ url: URL, attempt: Int) {
        if ForegroundApp.open(url) {
            Self.logBuffer.append("🔙 Callback opened via XCTest daemon")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                if ok {
                    Self.logBuffer.append("🔙 Callback opened via UIApplication (attempt \(attempt))")
                } else if attempt < 3 {
                    Self.logBuffer.append("🔙 Callback open failed, retrying (\(attempt))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.openCallback(url, attempt: attempt + 1)
                    }
                } else {
                    Self.logBuffer.append("🔙 Callback gave up after \(attempt) attempts")
                }
            }
        }
    }

    // MARK: - Notifications Setup

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register auth category with Allow/Deny actions
        let allowAction = UNNotificationAction(
            identifier: Self.allowActionID,
            title: "Allow",
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: Self.denyActionID,
            title: "Deny",
            options: [.destructive]
        )
        let authCategory = UNNotificationCategory(
            identifier: Self.authCategoryID,
            actions: [allowAction, denyAction],
            intentIdentifiers: [],
            options: []
        )

        // Register server-ready category with actions
        let enableRemoteAction = UNNotificationAction(
            identifier: Self.enableRemoteActionID,
            title: "Enable Remote Access",
            options: [.authenticationRequired]
        )
        let stopServerAction = UNNotificationAction(
            identifier: Self.stopServerActionID,
            title: "Stop Server",
            options: [.destructive, .authenticationRequired]
        )
        let serverReadyCategory = UNNotificationCategory(
            identifier: Self.serverReadyCategoryID,
            actions: [enableRemoteAction, stopServerAction],
            intentIdentifiers: [],
            options: []
        )

        // Remote-enabled category: Disable Remote + Stop
        let disableRemoteAction = UNNotificationAction(
            identifier: Self.disableRemoteActionID,
            title: "Disable Remote Access",
            options: [.authenticationRequired]
        )
        let serverRemoteCategory = UNNotificationCategory(
            identifier: Self.serverRemoteCategoryID,
            actions: [disableRemoteAction, stopServerAction],
            intentIdentifiers: [],
            options: []
        )

        // Stopped category: Copy Logs
        let copyLogsAction = UNNotificationAction(
            identifier: Self.copyLogsActionID,
            title: "Copy Logs",
            options: []
        )
        let serverStoppedCategory = UNNotificationCategory(
            identifier: Self.serverStoppedCategoryID,
            actions: [copyLogsAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([authCategory, serverReadyCategory, serverRemoteCategory, serverStoppedCategory])

        // Request permission
        let semaphore = DispatchSemaphore(value: 0)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Self.logBuffer.append(granted ? "🔔 Notifications enabled" : "🔕 Notifications denied")
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let requestID = response.notification.request.identifier

        // Handle "Copy Logs"
        if actionID == Self.copyLogsActionID {
            let logs = Self.logBuffer.dump()
            UIPasteboard.general.string = logs
            Self.logBuffer.append("📋 Copied \(Self.logBuffer.count) log entries to clipboard")
            completionHandler()
            return
        }

        // Handle "Disable Remote Access"
        if actionID == Self.disableRemoteActionID {
            Self.logBuffer.append("🔒 Remote access disabled via notification")
            disableRemoteAccess()
            completionHandler()
            return
        }

        // Handle "Stop Server"
        if actionID == Self.stopServerActionID {
            Self.logBuffer.append("🛑 Server stopped via notification")
            server?.stop()
            completionHandler()
            return
        }

        // Handle "Enable Remote Access" from server-ready notification
        if actionID == Self.enableRemoteActionID {
            Self.logBuffer.append("🌐 Remote access enabled via notification")
            enableRemoteAccess()
            completionHandler()
            return
        }

        // Handle auth request responses
        guard requestID.hasPrefix("auth-") else {
            completionHandler()
            return
        }

        authLock.lock()
        let authCompletion = pendingAuthCompletions.removeValue(forKey: requestID)
        authLock.unlock()

        switch actionID {
        case Self.allowActionID:
            Self.logBuffer.append("✅ Auth approved")
            authCompletion?(true)
        case Self.denyActionID:
            Self.logBuffer.append("❌ Auth denied")
            authCompletion?(false)
        case UNNotificationDefaultActionIdentifier:
            Self.logBuffer.append("✅ Auth approved (tap)")
            authCompletion?(true)
        case UNNotificationDismissActionIdentifier:
            Self.logBuffer.append("❌ Auth denied (dismiss)")
            authCompletion?(false)
        default:
            authCompletion?(false)
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Helpers

    private func wireServerStateChange() {
        server?.onStateChange = { [weak self] running in
            if !running {
                Self.logBuffer.append("Server stopped")
                self?.keepRunning = false
                self?.sendNotification(
                    title: "⏹️ iCTRL Server Stopped",
                    body: "The automation server has stopped.\nLong press to Copy Logs",
                    category: Self.serverStoppedCategoryID
                )
            }
        }
    }

    /// Methods that drive XCUITest and therefore MUST run on the main thread.
    /// Anything else (config, resolve_app, device_info, list_apps, is_locked, …)
    /// runs directly on the RPC queue — no main-thread hop, so it can't be delayed
    /// by (or delay) a slow UI action.
    private static let mainThreadMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "scroll", "drag",
        "page", "page_down", "page_up",
        "type", "screenshot", "page_source", "view_tree", "ui_tree",
        "scroll_to_element", "scroll_to", "find_element", "tap_element",
        "launch_app", "activate_app", "terminate_app",
        "home", "lock", "unlock",
    ]

    /// Compact one-line summary of the most useful params for the request log.
    /// Keeps element_id/x/y/bundle_id/direction/text-length so a crash post-mortem
    /// shows what an action targeted, without dumping the whole payload.
    private static func summarizeParams(_ params: [String: JSONValue]?) -> String {
        guard let params = params, !params.isEmpty else { return "" }
        let keys = ["element_id", "ref", "bundle_id", "x", "y", "direction", "match", "element_type", "submit"]
        var parts: [String] = []
        for k in keys {
            if let v = params[k] {
                switch v {
                case .string(let s): parts.append("\(k)='\(s)'")
                case .int(let i): parts.append("\(k)=\(i)")
                case .double(let d): parts.append("\(k)=\(Int(d))")
                case .bool(let b): parts.append("\(k)=\(b)")
                default: break
                }
            }
        }
        if let t = params["text"]?.stringValue { parts.append("text.len=\(t.count)") }
        return parts.joined(separator: " ")
    }

    /// Serial queue for RPC execution — OFF the main thread so a slow/blocking
    /// XCUITest call can't freeze the network listener (which would drop the whole
    /// service). Serial so actions still run one-at-a-time in order.
    private let rpcQueue = DispatchQueue(label: "com.openminis.ictrl.rpc")

    /// Hard ceiling for a single RPC before we report failure to the client. With
    /// quiescence disabled + fast defaults, real actions finish well under 1s, so
    /// a few seconds is already a hang. We reply failure quickly (so the client
    /// isn't left waiting and XCTest's own execution watchdog is less likely to
    /// kill the test); the underlying XCUITest call — which genuinely can't be
    /// force-cancelled — finishes on its own, and the serial queue drains it
    /// before the next request runs.
    private static let rpcTimeout: TimeInterval = 6

    /// Wire RPC dispatch + public logs onto a server instance.
    private func configureServerCallbacks(_ srv: JSONRPCServer) {
        srv.onRPCRequest = { [weak self] method, params, completion in
            guard let self = self else {
                completion(nil, .internalError)
                return
            }

            // Run the work on the serial RPC queue with a watchdog timeout so a
            // hung call reports back to the client instead of stalling forever.
            let done = DispatchSemaphore(value: 0)
            var replied = false
            let replyLock = NSLock()

            func replyOnce(_ result: ([String: JSONValue]?, JSONRPCError?)) {
                replyLock.lock()
                let first = !replied
                replied = true
                replyLock.unlock()
                if first { completion(result.0, result.1) }
            }

            self.rpcQueue.async {
                let start = ProcessInfo.processInfo.systemUptime
                var result: ([String: JSONValue]?, JSONRPCError?) = (nil, .internalError)

                // Log the request WITH key params BEFORE running it, so if this
                // call crashes/hangs the persisted log shows exactly what was
                // invoked (e.g. which element tap_element targeted). Redaction in
                // the log layer masks sensitive values.
                Self.logBuffer.append("→ \(method) \(Self.summarizeParams(params))")

                // XCUITest UI interactions (tap/swipe/type/…) MUST run on the main
                // thread — calling them off-main throws an ObjC NSException that,
                // uncaught on a background queue, aborts the whole runner (observed
                // crash). So we hop to the main thread for the actual dispatch, and
                // wrap it in an Obj-C @try/@catch so a stale/non-hittable element
                // turns into a JSON-RPC error instead of a SIGABRT.
                let work = {
                    if method == "config" {
                        result = self.handleConfig(params)
                    } else if let handler = self.actionHandler {
                        let reason = ObjCException.catching {
                            result = handler.dispatch(method: method, params: params)
                        }
                        if let reason = reason {
                            result = (nil, .serverError(
                                "\(method) failed: \(reason). The element may be gone/off-screen/not hittable, or the UI changed — re-check with page_source and retry."
                            ))
                        }
                    } else {
                        result = (nil, .internalError)
                    }
                }
                // Only XCUITest UI interactions must run on the main thread. Pure
                // data/network methods (config, resolve_app, device_info, list_apps,
                // logs, lock state) run directly on the RPC queue — no reason to
                // hop to (and potentially block) the main thread for them.
                if Self.mainThreadMethods.contains(method) && !Thread.isMainThread {
                    DispatchQueue.main.sync(execute: work)
                } else {
                    work()
                }

                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                Self.logBuffer.recordTiming(method: method, ms: ms, ok: result.1 == nil)
                if let err = result.1 { Self.logBuffer.append("← ERR \(method): \(err.message)") }
                done.signal()
                replyOnce(result)  // may be a no-op if the watchdog already replied
            }

            // Watchdog: if the work doesn't finish in time, tell the client now.
            DispatchQueue.global().async {
                if done.wait(timeout: .now() + Self.rpcTimeout) == .timedOut {
                    Self.logBuffer.append("⏱ TIMEOUT \(method) (>\(Int(Self.rpcTimeout))s) — still running in background")
                    replyOnce((nil, .serverError(
                        "\(method) exceeded \(Int(Self.rpcTimeout))s and may still be running on the device. " +
                        "Do NOT blindly retry — check GET /logs for a '✓ \(method)' entry first; the action may have already succeeded."
                    )))
                }
            }
        }
        srv.onLogsRequest = {
            let logs = Self.logBuffer.dumpRedacted()
            let timing = Self.logBuffer.timingSummary()
            return logs + "\n\n=== Timing summary (ms) ===\n" + timing
        }
        // Route the server's internal lifecycle messages into the persisted log.
        srv.onLog = { Self.logBuffer.append($0) }
        // Persisted-log endpoints (crash recovery — survive process restarts).
        srv.onLogFilesRequest = { Self.logBuffer.listLogFiles() }
        srv.onLogHistoryRequest = { Self.logBuffer.readLogFile(date: $0) }
    }

    // MARK: - Config RPC

    /// Read (no params) or update basic settings.
    /// Params: {allow_remote_access?: bool, listen_port?: int}
    /// Returns current effective config. Changing settings restarts the server.
    private func handleConfig(_ params: [String: JSONValue]?) -> ([String: JSONValue]?, JSONRPCError?) {
        var restartNeeded = false
        var newPort = UInt16(server?.port ?? 8200)
        var clearedSessions = 0
        var revokedSession: String?

        // Revoke a specific session by id.
        if let sid = params?["revoke_session_id"]?.stringValue {
            let existed = AuthManager.shared.activeSessions.contains { $0.id == sid }
            AuthManager.shared.revokeSession(id: sid)
            revokedSession = existed ? sid : nil
            Self.logBuffer.append(existed ? "🧹 Revoked session \(sid)" : "⚠️ revoke_session_id not found")
        }

        // Clear all authorized sessions (revoke every token) if requested.
        if params?["clear_sessions"]?.boolValue == true {
            clearedSessions = AuthManager.shared.activeSessions.count
            AuthManager.shared.revokeAll()
            Self.logBuffer.append("🧹 Cleared all authorized sessions (\(clearedSessions))")
        }

        if let remote = params?["allow_remote_access"]?.boolValue {
            if remote != remoteAccessEnabled {
                remoteAccessEnabled = remote
                Self.persistedRemoteAccess = remote
                restartNeeded = true
            }
        }

        if let portValue = params?["listen_port"]?.intValue {
            guard portValue > 0, portValue <= 65535 else {
                return (nil, JSONRPCError(code: -32602, message: "listen_port must be 1..65535", data: nil))
            }
            if UInt16(portValue) != newPort {
                newPort = UInt16(portValue)
                UserDefaults.standard.set(portValue, forKey: "serverPort")
                restartNeeded = true
            }
        }

        if restartNeeded {
            server?.onStateChange = nil
            server?.stop()
            let newServer = JSONRPCServer(port: newPort, localOnly: !remoteAccessEnabled)
            wireNewServer(newServer)
            do {
                try newServer.start()
                Self.logBuffer.append("⚙️ Config applied, server restarted on port \(newPort)")
            } catch {
                Self.logBuffer.append("🔴 Config restart failed: \(error)")
                return (nil, .serverError("Failed to restart server with new config: \(error.localizedDescription)"))
            }
        }

        let address = remoteAccessEnabled ? getDeviceAddress() : "127.0.0.1"
        let sessions = AuthManager.shared.activeSessions
        let iso = ISO8601DateFormatter()

        // Session list with the token masked (only a short prefix shown).
        let sessionList: [JSONValue] = sessions.map { s in
            let masked = String(s.token.prefix(8)) + "…"
            return .object([
                "session_id": .string(s.id),
                "client_name": .string(s.clientName),
                "token_prefix": .string(masked),
                "granted_at": .string(iso.string(from: s.grantedAt)),
                "last_active_at": .string(iso.string(from: s.lastActiveAt)),
                "expires_at": .string(iso.string(from: s.expiresAt)),
            ])
        }

        var result: [String: JSONValue] = [
            "allow_remote_access": .bool(remoteAccessEnabled),
            "listen_port": .int(Int(newPort)),
            "address": .string("\(address):\(newPort)"),
            "restarted": .bool(restartNeeded),
            "device_name": .string(UIDevice.current.name),
            "active_sessions": .int(sessions.count),
            "sessions": .array(sessionList),
            "cleared_sessions": .int(clearedSessions),
        ]
        if let revoked = revokedSession {
            result["revoked_session_id"] = .string(revoked)
        }

        // Per-action timing stats (ms).
        let timing: [JSONValue] = Self.logBuffer.timingStats().map { s in
            .object([
                "method": .string(s["method"] as? String ?? ""),
                "count": .int(s["count"] as? Int ?? 0),
                "avg_ms": .int(s["avg_ms"] as? Int ?? 0),
                "min_ms": .int(s["min_ms"] as? Int ?? 0),
                "max_ms": .int(s["max_ms"] as? Int ?? 0),
            ])
        }
        result["timing"] = .array(timing)

        return (result, nil)
    }

    private func wireNewServer(_ newServer: JSONRPCServer) {
        configureServerCallbacks(newServer)
        self.server = newServer
        wireServerStateChange()
    }

    private func sendNotification(title: String, body: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = category {
            content.categoryIdentifier = category
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func enableRemoteAccess() {
        guard !remoteAccessEnabled else { return }
        server?.onStateChange = nil
        server?.stop()
        remoteAccessEnabled = true
        Self.persistedRemoteAccess = true  // remember for next launch

        let newServer = JSONRPCServer(port: 8200, localOnly: false)
        wireNewServer(newServer)

        do {
            try newServer.start()
            let address = getDeviceAddress()
            Self.logBuffer.append("🌐 Remote access enabled on \(address):8200")
            sendNotification(
                title: "🌐 Remote Access Enabled",
                body: "Now accessible at \(address):8200\nLong press to Disable or Stop Server",
                category: Self.serverRemoteCategoryID
            )
        } catch {
            Self.logBuffer.append("🔴 Failed to enable remote access: \(error)")
        }
    }

    private func disableRemoteAccess() {
        guard remoteAccessEnabled else { return }
        server?.onStateChange = nil
        server?.stop()
        remoteAccessEnabled = false
        Self.persistedRemoteAccess = false  // remember for next launch

        let newServer = JSONRPCServer(port: 8200, localOnly: true)
        wireNewServer(newServer)

        do {
            try newServer.start()
            Self.logBuffer.append("🔒 Remote access disabled, local only")
            sendNotification(
                title: "🔒 Remote Access Disabled",
                body: "Now local only at 127.0.0.1:8200\nLong press for Remote Access or Stop Server",
                category: Self.serverReadyCategoryID
            )
        } catch {
            Self.logBuffer.append("🔴 Failed to disable remote access: \(error)")
        }
    }

    private func sendAuthNotification(clientName: String, requestID: String) {
        let content = UNMutableNotificationContent()
        content.title = "🔐 Authorization Request"
        content.body = "\"\(clientName)\" wants to control this device.\nLong press to Allow or Deny"
        content.sound = .default
        content.categoryIdentifier = Self.authCategoryID

        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func getDeviceAddress() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddr) }

        // Prefer en0 (Wi-Fi), fall back to any non-loopback IPv4
        var wifiAddr: String?
        var fallbackAddr: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let addr = String(cString: hostname)

            guard addr != "127.0.0.1" else { continue }

            let name = String(cString: interface.ifa_name)
            if name == "en0" {
                wifiAddr = addr
            } else if name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("bridge") {
                fallbackAddr = fallbackAddr ?? addr
            }
        }

        return wifiAddr ?? fallbackAddr ?? "127.0.0.1"
    }
}

// MARK: - AuthManagerDelegate

extension iCTRLUITests: AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String, completion: @escaping (Bool) -> Void) {
        let requestID = "auth-\(UUID().uuidString)"

        authLock.lock()
        pendingAuthCompletions[requestID] = completion
        authLock.unlock()

        Self.logBuffer.append("🔐 Auth request from \"\(clientName)\"")
        sendAuthNotification(clientName: clientName, requestID: requestID)
    }
}

extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
