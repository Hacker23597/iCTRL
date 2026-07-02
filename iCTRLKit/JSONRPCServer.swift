import Foundation
import Network

class JSONRPCServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    let port: UInt16
    private let localOnly: Bool
    private let queue = DispatchQueue(label: "com.openminis.ictrl.server")
    private(set) var isRunning = false

    var onRPCRequest: ((String, [String: JSONValue]?, @escaping ([String: JSONValue]?, JSONRPCError?) -> Void) -> Void)?
    var onStateChange: ((Bool) -> Void)?
    /// Returns redacted log text for the public (no-auth) GET /logs endpoint.
    var onLogsRequest: (() -> String)?

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
                print("🟢 iCTRL server ready on port \(self.port)")
            case .failed(let error):
                print("🔴 Server failed: \(error)")
                self.isRunning = false
                self.onStateChange?(false)
            case .cancelled:
                self.isRunning = false
                self.onStateChange?(false)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener.start(queue: queue)
    }

    func stop() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        print("🔴 iCTRL server stopped")
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

    private func receiveHTTP(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.processHTTPRequest(data, from: connection)
            }

            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    // MARK: - HTTP Parsing

    private func processHTTPRequest(_ data: Data, from connection: NWConnection) {
        guard let raw = String(data: data, encoding: .utf8) else {
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

        // Extract body
        var body: Data?
        if let range = raw.range(of: "\r\n\r\n") {
            let bodyString = String(raw[range.upperBound...])
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        route(method: method, path: path, headers: headers, body: body, connection: connection)
    }

    // MARK: - Routing

    private func route(method: String, path: String, headers: [String: String], body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/"):
            handleDocPage(connection: connection, headers: headers)

        case ("GET", "/schema"):
            handleSchema(connection: connection)

        case ("GET", "/logs"):
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
        } else {
            let html = RPCMethodRegistry.generateHTMLDoc()
            sendHTTPResponse(connection: connection, status: 200, contentType: "text/html; charset=utf-8", body: html)
        }
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

    private func handleLogs(connection: NWConnection) {
        // Public, no-auth endpoint. Content is redacted by the log provider.
        let logs = onLogsRequest?() ?? "(no logs available)"
        let header = "# iCTRL logs (redacted — sensitive values masked)\n\n"
        sendHTTPResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: header + logs)
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
        let statusCode = error.code == -32000 ? 401 : 200
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
