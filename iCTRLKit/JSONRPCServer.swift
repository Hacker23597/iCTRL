import CryptoKit
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
    var onVideoStream: ((NWConnection, _ fps: Double, _ quality: String, _ verbose: Bool) -> Void)?

    /// Fired right after a UI-mutating JSON-RPC completes (tap, swipe, home, …)
    /// so the host can nudge the video pipeline to emit a keyframe immediately
    /// instead of waiting for the next 1/fps tick — cuts perceived click-to-
    /// reflect latency at low fps.
    var onRPCUIChanged: (() -> Void)?
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

        // Logs can carry sensitive context even redacted. They are GETs that a
        // browser issues directly, so they can't carry an envelope body — they
        // use the same single-use ticket as /stream, minted over the encrypted
        // channel via the `stream_ticket` RPC.
        case ("GET", "/logs/files"):
            guard hasValidTicket(query) else { return sendUnauthorizedHTTP(connection) }
            handleLogFiles(connection: connection)

        case ("GET", "/logs/history"):
            guard hasValidTicket(query) else { return sendUnauthorizedHTTP(connection) }
            handleLogHistory(connection: connection, query: query)

        case ("GET", "/logs"):
            guard hasValidTicket(query) else { return sendUnauthorizedHTTP(connection) }
            handleLogs(connection: connection)

        case ("POST", "/pair"):
            handlePair(body: body, connection: connection, isLoopback: isLoopback(connection))

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

    /// POST /pair — grant a 32-byte token key K after on-device approval.
    ///
    /// Two modes, mirroring MinisApp's debug server:
    ///   - `{"client_name":"…","plain":true}` returns K in the clear. Accepted
    ///     ONLY from 127.0.0.1 (USB/iproxy), since anyone who sees the response
    ///     owns the device.
    ///   - `{"client_name":"…","pub":"<base64 raw 32B X25519>"}` wraps K against
    ///     an ephemeral device key, so it is safe over the LAN.
    ///
    /// Blocks until the user taps Allow (or the alert times out).
    private func handlePair(body: Data?, connection: NWConnection, isLoopback: Bool) {
        guard let body = body,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let clientName = obj["client_name"] as? String, !clientName.isEmpty else {
            sendPairError(connection, status: 400, code: "bad_request",
                          message: "client_name is required")
            return
        }

        let isPlain = obj["plain"] as? Bool ?? false
        var clientPub: Data?
        if !isPlain {
            guard let pubB64 = obj["pub"] as? String,
                  let pub = Data(base64Encoded: pubB64), pub.count == 32 else {
                sendPairError(connection, status: 400, code: "bad_request",
                              message: "Provide plain:true (loopback only) or pub (base64 raw 32B X25519)")
                return
            }
            clientPub = pub
        }
        if isPlain && !isLoopback {
            sendPairError(connection, status: 403, code: "plain_forbidden",
                          message: "Plain grant is localhost/USB only; use X25519 mode")
            return
        }

        AuthManager.shared.requestAuth(clientName: clientName) { [weak self] session in
            guard let self = self else { return }
            guard let session = session, let key = session.key else {
                self.sendPairError(connection, status: 403, code: "pair_denied",
                                   message: "User rejected or approval timed out")
                return
            }

            // Informational only: real expiry slides forward on every use.
            let expires = Int(session.expiresAt.timeIntervalSince1970)
            var response: [String: Any] = [
                "tok": session.id,
                "client_name": session.clientName,
                "expires": expires,
            ]

            if let clientPub = clientPub {
                do {
                    let devicePriv = Curve25519.KeyAgreement.PrivateKey()
                    let devicePub = devicePriv.publicKey.rawRepresentation
                    let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPub)
                    let shared = try devicePriv.sharedSecretFromKeyAgreement(with: peer)
                    let sharedData = shared.withUnsafeBytes { Data($0) }
                    let kWrap = SecureEnvelope.hmac(
                        sharedData,
                        Data(SecureEnvelope.labelPair.utf8) + clientPub + devicePub)
                    let pad = SecureEnvelope.hmac(kWrap, Data(SecureEnvelope.labelWrap.utf8))
                    response["pub"] = devicePub.base64EncodedString()
                    response["token_ct"] = Data(zip(key, pad).map { $0 ^ $1 }).hexString
                } catch {
                    AuthManager.shared.revokeSession(id: session.id)
                    self.sendPairError(connection, status: 400, code: "bad_request",
                                       message: "X25519 key agreement failed")
                    return
                }
            } else {
                response["token"] = key.hexString
            }

            if let data = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted),
               let json = String(data: data, encoding: .utf8) {
                self.sendHTTPResponse(connection: connection, status: 200,
                                      contentType: "application/json", body: json)
            }
        }
    }

    private func sendPairError(_ connection: NWConnection, status: Int, code: String, message: String) {
        let payload: [String: Any] = [
            "error": ["code": code, "message": message,
                      "server_ts": Int(Date().timeIntervalSince1970)],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        sendHTTPResponse(connection: connection, status: status, contentType: "application/json",
                         body: String(data: data, encoding: .utf8) ?? "{}")
    }

    /// GET /stream[.ts]?ticket=… — live H.264-in-MPEG-TS screen video.
    ///
    /// `<video src>` can't sign its own request, so this is the one endpoint not
    /// protected by an envelope. Instead it takes a single-use ticket minted over
    /// the encrypted channel (`stream_ticket` RPC): short-lived, consumed on
    /// first use, and useless to anyone who scrapes the URL afterwards.
    /// Optional ?fps=N (0.5–10, default 2). Hands the connection to the host's
    /// video streamer (kept open until the client disconnects).
    private func handleVideoStream(headers: [String: String], query: String, connection: NWConnection) {
        guard hasValidTicket(query) else {
            sendHTTPResponse(connection: connection, status: 401,
                             body: "Unauthorized: GET /stream needs ?ticket=<t>. "
                                 + "Mint one with the stream_ticket RPC over the encrypted channel.")
            return
        }
        guard let handoff = onVideoStream else {
            sendHTTPResponse(connection: connection, status: 503, body: "Video streaming unavailable")
            return
        }
        var fps = 2.0
        var quality = "auto"
        var verbose = false
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "fps":     if let v = Double(kv[1]) { fps = v }
            case "quality": quality = String(kv[1])
            case "verbose": verbose = (kv[1] == "1" || kv[1] == "true")
            default: break
            }
        }
        handedOff.insert(ObjectIdentifier(connection))
        handoff(connection, fps, quality, verbose)
    }

    /// True if the query carries a valid single-use `ticket=`.
    ///
    /// Browser-issued GETs (`<video src>`, log links) can't carry an encrypted
    /// envelope, so they present a ticket instead — minted over the encrypted
    /// channel by the `stream_ticket` RPC, valid ~60s, and consumed on first use.
    /// No long-lived secret ever appears in a URL.
    private func hasValidTicket(_ query: String) -> Bool {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "ticket",
               let ticket = String(kv[1]).removingPercentEncoding,
               AuthManager.shared.consumeStreamTicket(ticket) {
                return true
            }
        }
        return false
    }

    /// Whether the peer is 127.0.0.1/::1 — the only source allowed to request a
    /// plaintext key grant at pairing time.
    private func isLoopback(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else {
            return false
        }
        switch host {
        case .ipv4(let addr): return addr.isLoopback
        case .ipv6(let addr): return addr.isLoopback
        @unknown default: return false
        }
    }

    /// Plain-text 401 for non-RPC (e.g. GET /logs) endpoints.
    private func sendUnauthorizedHTTP(_ connection: NWConnection) {
        sendHTTPResponse(connection: connection, status: 401,
                         body: "Unauthorized: append ?ticket=<t> (mint one with the stream_ticket RPC over the encrypted channel).")
    }

    private func handleRPC(headers: [String: String], body: Data?, connection: NWConnection) {
        // Every /rpc call must arrive as a sealed v1 envelope. There is no
        // plaintext path: an unsealed body is rejected before it is even parsed
        // as JSON-RPC, so an unauthenticated caller learns nothing about the
        // method surface.
        guard let body = body,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendAuthError(connection, status: 400, code: "bad_envelope",
                          message: "Body must be a v1 encrypted envelope")
            return
        }
        guard SecureEnvelope.looksLikeEnvelope(obj) else {
            sendAuthError(connection, status: 401, code: "auth_required",
                          message: "Encrypted envelope required. POST /pair to obtain a key, "
                                 + "then wrap each JSON-RPC body per the v1 protocol (see /skill).")
            return
        }

        let opened: (tokId: String, plaintext: String, seal: (String) -> String)
        do {
            opened = try AuthManager.shared.openEnvelope(obj)
        } catch let failure as SecureEnvelope.Failure {
            // 401 for anything token/auth related so clients know to re-pair;
            // 400 only for a structurally broken envelope.
            let status = failure.code == "bad_envelope" ? 400 : 401
            sendAuthError(connection, status: status, code: failure.code, message: failure.message)
            return
        } catch {
            sendAuthError(connection, status: 401, code: "auth_failed", message: "Authentication failed")
            return
        }

        let seal = opened.seal
        guard let inner = opened.plaintext.data(using: .utf8),
              let rpcRequest = try? JSONDecoder().decode(JSONRPCRequest.self, from: inner) else {
            sendSealed(connection, seal: seal, json: Self.errorJSON(nil, .parseError))
            return
        }
        guard rpcRequest.jsonrpc == "2.0" else {
            sendSealed(connection, seal: seal, json: Self.errorJSON(rpcRequest.id, .invalidRequest))
            return
        }

        // `stream_ticket` is served here rather than in the action handler: it
        // mints credentials, so it must stay inside the authenticated boundary
        // and needs the token id this envelope authenticated as.
        if rpcRequest.method == "stream_ticket" {
            // Use the identity the envelope actually AUTHENTICATED as — never
            // re-read obj["tok"], which is unverified input.
            guard let issued = AuthManager.shared.issueStreamTicket(forTokenId: opened.tokId) else {
                sendSealed(connection, seal: seal,
                           json: Self.errorJSON(rpcRequest.id, .internalError))
                return
            }
            let result: [String: JSONValue] = [
                "ticket": .string(issued.ticket),
                "expires_in": .int(issued.expiresIn),
                "hint": .string("Append ?ticket=<ticket> to GET /stream or /logs. "
                              + "Single use, expires in \(issued.expiresIn)s."),
            ]
            sendSealed(connection, seal: seal, json: Self.resultJSON(rpcRequest.id, result))
            return
        }

        guard let handler = onRPCRequest else {
            sendSealed(connection, seal: seal, json: Self.errorJSON(rpcRequest.id, .internalError))
            return
        }

        let method = rpcRequest.method
        handler(method, rpcRequest.params) { [weak self] result, error in
            let json = error.map { Self.errorJSON(rpcRequest.id, $0) }
                ?? Self.resultJSON(rpcRequest.id, result ?? [:])
            self?.sendSealed(connection, seal: seal, json: json)
            // Latency shortcut: when a UI-mutating RPC finishes, tell the video
            // pipeline to grab an extra keyframe *now* instead of waiting for
            // the next 1/fps tick. Without this, a 2 fps tap can wait up to
            // ~500 ms before the user sees the reaction.
            if Self.uiMutatingMethods.contains(method) {
                self?.onRPCUIChanged?()
            }
        }
    }

    /// Encrypt a JSON-RPC reply into a response envelope and write it out.
    /// Always HTTP 200: transport succeeded, and the real status is inside the
    /// sealed body (an eavesdropper shouldn't learn outcomes from status codes).
    private func sendSealed(_ connection: NWConnection, seal: (String) -> String, json: String) {
        sendHTTPResponse(connection: connection, status: 200,
                         contentType: "application/json", body: seal(json))
    }

    /// Auth failures are sent in the CLEAR — the client has no usable key yet
    /// (or the one it used was rejected), so a sealed reply would be unreadable.
    private func sendAuthError(_ connection: NWConnection, status: Int, code: String, message: String) {
        let payload: [String: Any] = [
            "error": ["code": code, "message": message,
                      "server_ts": Int(Date().timeIntervalSince1970)],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        sendHTTPResponse(connection: connection, status: status, contentType: "application/json",
                         body: String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func resultJSON(_ id: JSONValue?, _ result: [String: JSONValue]) -> String {
        encode(JSONRPCResponse(result: result, error: nil, id: id))
    }

    private static func errorJSON(_ id: JSONValue?, _ error: JSONRPCError) -> String {
        encode(JSONRPCResponse(result: nil, error: error, id: id))
    }

    private static func encode(_ response: JSONRPCResponse) -> String {
        guard let data = try? JSONEncoder().encode(response),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}"#
        }
        return json
    }

    /// RPCs that visibly change what's on screen — used to trigger an out-of-
    /// band keyframe on the video stream so the browser reflects the change
    /// with sub-500 ms delay instead of waiting for the next capture tick.
    private static let uiMutatingMethods: Set<String> = [
        "tap", "double_tap", "long_press", "swipe", "drag_up", "drag_down",
        "drag_move", "scroll", "scroll_to_element", "tap_element", "find_and_tap", "page",
        "type", "clear_text", "home", "lock", "unlock",
        "launch_app", "activate_app", "terminate_app", "open_url",
    ]

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
