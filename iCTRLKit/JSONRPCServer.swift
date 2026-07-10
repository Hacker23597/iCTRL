import Foundation
import Network

class JSONRPCServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    /// Connections handed off to a long-lived streamer (video) — the base receive
    /// loop must not cancel these.
    private var handedOff: Set<ObjectIdentifier> = []
    let port: UInt16
    private let localOnly: Bool
    private let queue = DispatchQueue(label: "com.openminis.ictrl.server")
    private(set) var isRunning = false

    var onRPCRequest: ((String, [String: JSONValue]?, @escaping ([String: JSONValue]?, JSONRPCError?) -> Void) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    /// Hand off an authorized connection to the video streamer (host owns the
    /// frame grabber + VideoStreamer). The server stops managing this connection
    /// once handed off — the streamer keeps it alive and closes it on disconnect.
    var onVideoStream: ((NWConnection, _ fps: Double, _ verbose: Bool) -> Void)?
    /// Returns redacted log text for the (auth-required) GET /logs endpoint.
    var onLogsRequest: (() -> String)?

    /// Lists persisted daily log files (names + sizes) for GET /logs/files.
    var onLogFilesRequest: (() -> String)?

    /// Returns the redacted contents of a persisted log file for
    /// GET /logs/history?date=YYYY-MM-DD (defaults to today if absent).
    var onLogHistoryRequest: ((String?) -> String)?

    /// Routes internal server-lifecycle messages to the host's log sink so they
    /// land in the persisted log file, not just the console.
    var onLog: ((String) -> Void)?

    private func log(_ message: String) {
        onLog?(message)
        print(message)
    }

    init(port: UInt16 = 8200, localOnly: Bool = false) {
        self.port = port
        self.localOnly = localOnly
    }

    func start() throws {
        guard !isRunning else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "JSONRPCServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }

        let listener: NWListener
        if localOnly {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: nwPort)
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.onStateChange?(true)
                self.log("🟢 iCTRL server ready on port \(self.port)")
            case .failed(let error):
                self.log("🔴 Server failed: \(error)")
                self.isRunning = false
                self.onStateChange?(false)
            case .cancelled:
                self.isRunning = false
                self.onStateChange?(false)
                self.log("⚪️ NWListener cancelled")
            case .waiting(let error):
                self.log("🟡 NWListener waiting: \(error)")
            case .setup:
                self.log("🔧 NWListener setup")
            @unknown default:
                self.log("❔ NWListener state: \(state)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener.start(queue: queue)
        log("🔊 NWListener.start called (port \(port), localOnly=\(localOnly))")
    }

    func stop() {
        log("🔻 JSONRPCServer.stop called")
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        log("🔴 iCTRL server stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveHTTP(from: connection)
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveHTTP(from connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var acc = buffer
            if let data = data, !data.isEmpty { acc.append(data) }

            // A full HTTP request needs the header terminator AND, for a body, the
            // whole Content-Length. If we don't have it all yet, keep receiving —
            // TCP can split a request across segments (common under concurrent /
            // rapid requests), and parsing a half-received body was the cause of
            // spurious "parse error" responses.
            switch Self.requestState(of: acc) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()  // peer closed before sending it all
                } else {
                    self.receiveHTTP(from: connection, buffer: acc)  // wait for more
                }
            case .complete(let headerEnd, let contentLength):
                self.processHTTPRequest(acc, headerEnd: headerEnd, contentLength: contentLength, from: connection)
                // A streaming route (e.g. /stream) takes ownership of the socket
                // and keeps it open — don't cancel it here.
                if self.handedOff.contains(ObjectIdentifier(connection)) { return }
                if isComplete || error != nil { connection.cancel() }
            }
        }
    }

    // MARK: - HTTP Parsing

    private enum RequestState {
        case incomplete
        case complete(headerEnd: Int, contentLength: Int)
    }

    /// Determine whether `acc` holds a complete HTTP request. Operates on raw
    /// bytes (binary-safe) and honors Content-Length.
    private static func requestState(of acc: Data) -> RequestState {
        // Find the CRLFCRLF header/body separator.
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let r = acc.range(of: sep) else { return .incomplete }
        let headerEnd = r.upperBound
        // Parse Content-Length from the header block (case-insensitive).
        let headerData = acc.subdata(in: acc.startIndex..<r.lowerBound)
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let p = line.split(separator: ":", maxSplits: 1)
            if p.count == 2, p[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? 0
                break
            }
        }
        let haveBody = acc.count - headerEnd
        return haveBody >= contentLength ? .complete(headerEnd: headerEnd, contentLength: contentLength)
                                         : .incomplete
    }

    private func processHTTPRequest(_ data: Data, headerEnd: Int, contentLength: Int, from connection: NWConnection) {
        let headerData = data.subdata(in: data.startIndex..<headerEnd)
        guard let raw = String(data: headerData, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendHTTPResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                headers[String(headerParts[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(headerParts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract the body as raw bytes (exactly Content-Length), binary-safe.
        var body: Data?
        if contentLength > 0 {
            let end = min(data.count, headerEnd + contentLength)
            body = data.subdata(in: headerEnd..<end)
        }

        route(method: method, path: path, headers: headers, body: body, connection: connection)
    }

    // MARK: - Routing

    private func route(method: String, path: String, headers: [String: String], body: Data?, connection: NWConnection) {
        // Split off any query string so path matching is exact.
        let rawPath = path
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let query = rawPath.contains("?") ? String(rawPath.split(separator: "?", maxSplits: 1).dropFirst().first ?? "") : ""

        switch (method, pathOnly) {
        case ("GET", "/"):
            handleDocPage(connection: connection, headers: headers)

        case ("GET", "/schema"):
            handleSchema(connection: connection)

        case ("GET", "/skill"), ("GET", "/skill.md"), ("GET", "/SKILL.md"):
            handleSkill(connection: connection)

        case ("GET", "/docs"):
            handleDocsPage(connection: connection)

        case ("GET", "/stream"), ("GET", "/stream.ts"):
            handleVideoStream(headers: headers, query: query, connection: connection)

        case ("GET", "/remote"):
            // The page itself is unauthenticated (it needs to load so the user can
            // paste a token). The RPC + stream calls it makes are authenticated.
            sendHTTPResponse(connection: connection, status: 200,
                             contentType: "text/html; charset=utf-8", body: RemoteHTML.page)

        // Logs can contain sensitive context even when redacted, so they now
        // require a valid bearer token — same as /rpc.
        case ("GET", "/logs/files"):
            guard isAuthorized(headers) else { return sendUnauthorizedHTTP(connection) }
            handleLogFiles(connection: connection)

        case ("GET", "/logs/history"):
            guard isAuthorized(headers) else { return sendUnauthorizedHTTP(connection) }
            handleLogHistory(connection: connection, query: query)

        case ("GET", "/logs"):
            guard isAuthorized(headers) else { return sendUnauthorizedHTTP(connection) }
            handleLogs(connection: connection)

        case ("POST", "/auth"):
            handleAuth(body: body, connection: connection)

        case ("POST", "/rpc"):
            handleRPC(headers: headers, body: body, connection: connection)

        case ("OPTIONS", _):
            sendHTTPResponse(connection: connection, status: 200, headers: corsHeaders(), body: "")

        default:
            sendHTTPResponse(connection: connection, status: 404, body: "Not Found")
        }
    }

    // MARK: - Handlers

    /// GET / — content-negotiated:
    ///   Accept: application/json  → the JSON schema (machine-readable methods)
    ///   Accept: text/html         → the visual HTML docs page (for browsers)
    ///   default (agents/curl)     → the SKILL.md operating manual (Markdown)
    /// The HTML page is also always at /docs.
    private func handleDocPage(connection: NWConnection, headers: [String: String]) {
        let accept = headers["accept"] ?? ""
        if accept.contains("application/json") {
            let schema = RPCMethodRegistry.generateSchemaDocument()
            if let jsonData = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: jsonString)
            } else {
                sendHTTPResponse(connection: connection, status: 500, body: "Failed to generate schema")
            }
        } else if accept.contains("text/html") {
            // A real browser asked — give it the visual page.
            handleDocsPage(connection: connection)
        } else {
            // Default (agents, curl): the Skill manual — read once, drive the phone.
            handleSkill(connection: connection)
        }
    }

    private func handleDocsPage(connection: NWConnection) {
        let html = RPCMethodRegistry.generateHTMLDoc()
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/html; charset=utf-8", body: html)
    }

    private func handleSchema(connection: NWConnection) {
        let schema = RPCMethodRegistry.generateSchemaDocument()
        if let jsonData = try? JSONSerialization.data(withJSONObject: schema, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: jsonString)
        } else {
            sendHTTPResponse(connection: connection, status: 500, body: "Failed to generate schema")
        }
    }

    /// GET /skill — the operating manual in Skill (Markdown + frontmatter) format,
    /// so an agent can read it once and treat iCTRL as a Skill. Served from the
    /// bundled SKILL.md resource; falls back to a pointer if the resource is
    /// missing. The dynamic method list stays at /schema.
    private func handleSkill(connection: NWConnection) {
        let md = Self.bundledSkillMarkdown()
            ?? "# iCTRL\n\nOperating manual resource missing. Fetch GET /schema for the machine-readable method list and guidance.\n"
        sendHTTPResponse(connection: connection, status: 200,
                         contentType: "text/markdown; charset=utf-8", body: md)
    }

    /// Load SKILL.md from whichever bundle carries it. The resource ships inside
    /// the UITests .xctest bundle (this class's bundle), not runner.app's root, so
    /// try Bundle(for:) first, then main + all loaded bundles as a fallback.
    static func bundledSkillMarkdown() -> String? {
        let candidates = [Bundle(for: JSONRPCServer.self), Bundle.main] + Bundle.allBundles
        for b in candidates {
            if let url = b.url(forResource: "SKILL", withExtension: "md"),
               let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
        }
        return nil
    }

    private func handleLogs(connection: NWConnection) {
        // Auth-required (checked in route()). Content is still redacted as defense in depth.
        let logs = onLogsRequest?() ?? "(no logs available)"
        let header = "# iCTRL logs (redacted — sensitive values masked)\n\n"
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: header + logs)
    }

    /// GET /logs/files — list persisted daily log files (survive crashes/restarts).
    private func handleLogFiles(connection: NWConnection) {
        let listing = onLogFilesRequest?() ?? "(no log files)"
        let header = "# iCTRL persisted log files\n# GET /logs/history?date=YYYY-MM-DD to read one\n\n"
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: header + listing)
    }

    /// GET /logs/history?date=YYYY-MM-DD — dump a persisted day's log (redacted).
    /// This is how you recover the log from BEFORE a crash/restart, since /logs
    /// only holds the current process's in-memory buffer.
    private func handleLogHistory(connection: NWConnection, query: String) {
        // Parse date=... from the query string.
        var date: String? = nil
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "date" {
                date = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        let content = onLogHistoryRequest?(date) ?? "(no history log available)"
        let header = "# iCTRL persisted log (redacted)\(date.map { " — \($0)" } ?? " — today")\n\n"
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: header + content)
    }

    private func handleAuth(body: Data?, connection: NWConnection) {
        guard let body = body else {
            sendJSONRPCError(nil, error: .invalidRequest, connection: connection)
            return
        }

        let decoder = JSONDecoder()
        guard let authReq = try? decoder.decode(AuthRequest.self, from: body) else {
            sendJSONRPCError(nil, error: JSONRPCError(code: -32602, message: "Missing or invalid client_name", data: nil), connection: connection)
            return
        }

        AuthManager.shared.requestAuth(clientName: authReq.clientName) { [weak self] session in
            guard let session = session else {
                self?.sendHTTPResponse(
                    connection: connection,
                    status: 403,
                    contentType: "application/json",
                    body: "{\"error\": \"Authorization denied\"}"
                )
                return
            }

            let ttl = Int(session.expiresAt.timeIntervalSince(session.grantedAt))
            let response: [String: Any] = [
                "token": session.token,
                "session_id": session.id,
                "client_name": session.clientName,
                "expires_at": ISO8601DateFormatter().string(from: session.expiresAt),
                "expires_in": ttl,
            ]

            if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self?.sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: jsonString)
            }
        }
    }

    /// GET /stream[.ts] — live H.264-in-MPEG-TS screen video. Auth via Bearer /
    /// Basic / ?token=. Optional ?fps=N (0.5–10, default 2). Hands the connection
    /// to the host's video streamer (kept open until the client disconnects).
    private func handleVideoStream(headers: [String: String], query: String, connection: NWConnection) {
        guard isAuthorized(headers, query: query) else {
            // Send a Basic-auth challenge so browsers/players prompt for creds.
            sendHTTPResponse(connection: connection, status: 401,
                             headers: ["WWW-Authenticate": "Basic realm=\"iCTRL\""],
                             body: "Unauthorized: pass the token via Bearer, Basic auth, or ?token=.")
            return
        }
        guard let handoff = onVideoStream else {
            sendHTTPResponse(connection: connection, status: 503, body: "Video streaming unavailable")
            return
        }
        var fps = 2.0
        var verbose = false
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "fps":     if let v = Double(kv[1]) { fps = v }
            case "verbose": verbose = (kv[1] == "1" || kv[1] == "true")
            default: break
            }
        }
        handedOff.insert(ObjectIdentifier(connection))
        handoff(connection, fps, verbose)
    }

    /// True if the request carries a valid token via EITHER `Authorization:
    /// Bearer <token>` OR HTTP Basic auth (so a browser/player can pass the token
    /// in the URL, e.g. http://<token>@host:8200/stream — username or password may
    /// be the token; also accepts ?token=<token> as a last resort for players that
    /// can't set headers). Also accepts a token in the query for URL-only clients.
    private func isAuthorized(_ headers: [String: String], query: String = "") -> Bool {
        if let authHeader = headers["authorization"] {
            let lower = authHeader.lowercased()
            if lower.hasPrefix("bearer ") {
                let token = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if AuthManager.shared.validateToken(token) { return true }
            }
            if lower.hasPrefix("basic ") {
                let b64 = String(authHeader.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if let data = Data(base64Encoded: b64),
                   let creds = String(data: data, encoding: .utf8) {
                    // "user:pass" — the token may be in either field.
                    let parts = creds.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    for p in parts where AuthManager.shared.validateToken(String(p)) { return true }
                }
            }
        }
        // ?token=<token> in the query string (URL-only players).
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "token",
               let tok = String(kv[1]).removingPercentEncoding,
               AuthManager.shared.validateToken(tok) { return true }
        }
        return false
    }

    /// Plain-text 401 for non-RPC (e.g. GET /logs) endpoints.
    private func sendUnauthorizedHTTP(_ connection: NWConnection) {
        sendHTTPResponse(connection: connection, status: 401,
                         body: "Unauthorized: a valid Bearer token is required to read logs.")
    }

    private func handleRPC(headers: [String: String], body: Data?, connection: NWConnection) {
        // Auth check
        guard let authHeader = headers["authorization"],
              authHeader.lowercased().hasPrefix("bearer ") else {
            sendJSONRPCError(nil, error: .unauthorized, connection: connection)
            return
        }

        let token = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard AuthManager.shared.validateToken(token) else {
            sendJSONRPCError(nil, error: .unauthorized, connection: connection)
            return
        }

        // Parse JSON-RPC request
        guard let body = body else {
            sendJSONRPCError(nil, error: .parseError, connection: connection)
            return
        }

        let decoder = JSONDecoder()
        guard let rpcRequest = try? decoder.decode(JSONRPCRequest.self, from: body) else {
            sendJSONRPCError(nil, error: .parseError, connection: connection)
            return
        }

        guard rpcRequest.jsonrpc == "2.0" else {
            sendJSONRPCError(rpcRequest.id, error: .invalidRequest, connection: connection)
            return
        }

        // Dispatch to handler
        guard let handler = onRPCRequest else {
            sendJSONRPCError(rpcRequest.id, error: .internalError, connection: connection)
            return
        }

        handler(rpcRequest.method, rpcRequest.params) { [weak self] result, error in
            if let error = error {
                self?.sendJSONRPCError(rpcRequest.id, error: error, connection: connection)
            } else {
                self?.sendJSONRPCResult(rpcRequest.id, result: result ?? [:], connection: connection)
            }
        }
    }

    // MARK: - Response Helpers

    private func sendJSONRPCResult(_ id: JSONValue?, result: [String: JSONValue], connection: NWConnection) {
        let response = JSONRPCResponse(result: result, error: nil, id: id)
        if let data = try? JSONEncoder().encode(response), let str = String(data: data, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: 200, contentType: "application/json", body: str)
        }
    }

    private func sendJSONRPCError(_ id: JSONValue?, error: JSONRPCError, connection: NWConnection) {
        let response = JSONRPCResponse(result: nil, error: error, id: id)
        // Only a genuine auth failure maps to HTTP 401. Every other JSON-RPC error
        // (business/timeout/-32000, parse, invalid params, …) is a processed
        // request whose failure travels in the JSON body, so HTTP stays 200 — else
        // a slow/timed-out action reads as "unauthorized" to clients.
        let statusCode = error.code == JSONRPCError.unauthorizedCode ? 401 : 200
        if let data = try? JSONEncoder().encode(response), let str = String(data: data, encoding: .utf8) {
            sendHTTPResponse(connection: connection, status: statusCode, contentType: "application/json", body: str)
        }
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
        ]
    }

    private func sendHTTPResponse(connection: NWConnection, status: Int, headers: [String: String] = [:], contentType: String = "text/plain", body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let bodyData = body.data(using: .utf8) ?? Data()

        var allHeaders = corsHeaders()
        allHeaders["Content-Type"] = contentType
        allHeaders["Content-Length"] = "\(bodyData.count)"
        allHeaders["Connection"] = "close"
        for (k, v) in headers {
            allHeaders[k] = v
        }

        let headerString = allHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        let responseString = "HTTP/1.1 \(status) \(statusText)\r\n\(headerString)\r\n\r\n"

        var responseData = responseString.data(using: .utf8) ?? Data()
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    deinit {
        stop()
    }
}
