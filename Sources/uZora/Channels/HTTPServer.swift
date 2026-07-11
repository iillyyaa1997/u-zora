import Foundation
import Network
import os

/// Minimal HTTP/1.1 server over `Network.framework`'s `NWListener`.
///
/// Binds explicitly to `127.0.0.1` on the requested port (or ephemeral
/// `0` for tests). Speaks just enough HTTP/1.1 to serve the uZora bridge
/// channels:
///
/// - `GET /status`, `GET /alerts`, `GET /probes`, `GET /metrics` — REST
/// - `GET /stream` — Server-Sent Events
/// - `POST /mcp` — JSON-RPC 2.0 (MCP) endpoint
///
/// Limitations (intentional — single-developer monolith, loopback only):
///
/// - No chunked transfer-encoding on **requests** (the bridge is
///   read-only; bodies are MCP JSON-RPC envelopes, capped at 256 KiB).
/// - SSE responses are streamed unchunked — `Network.framework` writes
///   raw bytes and clients see them as they arrive over TCP.
/// - No HTTP/2, no TLS (loopback only, see ADR-0002).
/// - No persistent connections — every request closes the socket after
///   the response, **except** for `/stream` which stays open until the
///   client disconnects.
public actor HTTPServer {

    public enum Error: Swift.Error, Equatable {
        case bindFailed(String)
        case alreadyRunning
    }

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    public typealias StreamHandler = @Sendable (HTTPRequest, StreamingResponseSink) async -> Void

    public struct Route: Sendable {
        public let method: String
        public let path: String
        public let handler: HandlerKind

        public init(method: String, path: String, handler: HandlerKind) {
            self.method = method
            self.path = path
            self.handler = handler
        }
    }

    public enum HandlerKind: Sendable {
        case unary(Handler)
        case streaming(StreamHandler)
    }

    public let requestedPort: UInt16
    private(set) public var boundPort: UInt16 = 0

    private var routes: [Route] = []
    private var listener: NWListener?
    private var connections: Set<ConnectionBox> = []
    private let queue = DispatchQueue(label: "place.unicorns.uzora.httpserver")
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "http-server")

    public init(port: UInt16) {
        self.requestedPort = port
    }

    public func register(_ route: Route) {
        routes.append(route)
    }

    public func register(method: String, path: String, _ handler: @escaping Handler) {
        routes.append(Route(method: method, path: path, handler: .unary(handler)))
    }

    public func registerStreaming(method: String, path: String, _ handler: @escaping StreamHandler) {
        routes.append(Route(method: method, path: path, handler: .streaming(handler)))
    }

    public func start() async throws {
        if listener != nil { throw Error.alreadyRunning }

        let params = NWParameters.tcp
        // `acceptLocalOnly` is the kernel-level enforcement: NWListener
        // refuses any connection arriving from a non-loopback address.
        // The socket may still appear as `IPv6 *` in `lsof` (dual-stack
        // listener) but inbound from a LAN peer hard-fails. Verified by
        // smoke test: curl from `ipconfig getifaddr en0` → empty/refused.
        params.acceptLocalOnly = true
        params.includePeerToPeer = false
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.connectionTimeout = 5
            tcpOptions.enableKeepalive = false
        }

        let chosenPort: NWEndpoint.Port = requestedPort == 0
            ? .any
            : NWEndpoint.Port(rawValue: requestedPort)!

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: chosenPort)
        } catch {
            throw Error.bindFailed("NWListener init: \(error)")
        }

        let onReady = OneShotContinuation<UInt16, Swift.Error>()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                Task { await self.applyBound(port: port) }
                onReady.resume(returning: port)
            case .failed(let err):
                onReady.resume(throwing: Error.bindFailed("listener failed: \(err)"))
            case .cancelled:
                onReady.resume(throwing: Error.bindFailed("listener cancelled before ready"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection: connection) }
        }
        listener.start(queue: queue)
        self.listener = listener

        do {
            let port = try await onReady.value()
            self.boundPort = port
            log.info("HTTP server bound on 127.0.0.1:\(port, privacy: .public)")
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        for c in connections {
            c.connection.cancel()
        }
        connections.removeAll()
    }

    private func applyBound(port: UInt16) {
        self.boundPort = port
    }

    // MARK: - Connection lifecycle

    private func accept(connection: NWConnection) {
        let box = ConnectionBox(connection: connection)
        connections.insert(box)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.serve(box: box) }
            case .failed, .cancelled:
                Task { await self.drop(box: box) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func drop(box: ConnectionBox) {
        connections.remove(box)
    }

    private func serve(box: ConnectionBox) async {
        let connection = box.connection
        // Read the request. We use a 32 KiB cap for headers + body for
        // unary handlers; streaming handlers read once then take over.
        let raw = await ConnectionIO.readUpTo(connection: connection, max: 256 * 1024, headerOnly: false)
        guard let raw else {
            connection.cancel()
            return
        }
        guard let request = HTTPRequest.parse(raw) else {
            await ConnectionIO.write(connection: connection, data: HTTPResponse.badRequest("malformed").rawHTTP())
            connection.cancel()
            return
        }

        // Match routes (longest-prefix is sufficient — every route is exact).
        let match = routes.first { $0.method == request.method && $0.path == request.path }
        if let match {
            switch match.handler {
            case .unary(let handler):
                let response = await handler(request)
                await ConnectionIO.write(connection: connection, data: response.rawHTTP())
                connection.cancel()
            case .streaming(let handler):
                let sink = StreamingResponseSink(connection: connection)
                // Send the SSE preamble + initial headers.
                await sink.writeInitialHeaders()
                await handler(request, sink)
                connection.cancel()
            }
        } else {
            await ConnectionIO.write(
                connection: connection,
                data: HTTPResponse.notFound("no route for \(request.method) \(request.path)").rawHTTP()
            )
            connection.cancel()
        }
    }
}

// MARK: - HTTPRequest / HTTPResponse

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    /// Parse an HTTP/1.1 request. Returns nil if the request line or
    /// headers are malformed. Body is read as raw bytes after `\r\n\r\n`.
    public static func parse(_ raw: Data) -> HTTPRequest? {
        guard let crlfcrlf = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            return nil
        }
        let headBytes = raw[..<crlfcrlf.lowerBound]
        let body = raw[crlfcrlf.upperBound...]
        guard let headString = String(data: headBytes, encoding: .utf8) else { return nil }
        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        // Split path & query.
        var path = target
        var query: [String: String] = [:]
        if let qIdx = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qIdx])
            let qs = target[target.index(after: qIdx)...]
            for kv in qs.split(separator: "&") {
                let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    let k = decodeURLComponent(String(parts[0]))
                    let v = decodeURLComponent(String(parts[1]))
                    query[k] = v
                } else if parts.count == 1 {
                    query[decodeURLComponent(String(parts[0]))] = ""
                }
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: Data(body))
    }

    private static func decodeURLComponent(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let statusText: String
    public let headers: [(String, String)]
    public let body: Data

    public init(status: Int, statusText: String, headers: [(String, String)], body: Data) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    public func rawHTTP() -> Data {
        var s = "HTTP/1.1 \(status) \(statusText)\r\n"
        var seenContentLength = false
        var seenConnection = false
        for (k, v) in headers {
            if k.lowercased() == "content-length" { seenContentLength = true }
            if k.lowercased() == "connection" { seenConnection = true }
            s += "\(k): \(v)\r\n"
        }
        if !seenContentLength {
            s += "Content-Length: \(body.count)\r\n"
        }
        if !seenConnection {
            s += "Connection: close\r\n"
        }
        s += "\r\n"
        var data = s.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }

    // MARK: - Factories

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        do {
            let body = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return HTTPResponse(
                status: status,
                statusText: HTTPResponse.statusText(for: status),
                headers: [("Content-Type", "application/json; charset=utf-8")],
                body: body
            )
        } catch {
            return HTTPResponse.serverError("json encode failed: \(error)")
        }
    }

    /// Factory for already-encoded Codable payloads.
    public static func jsonData(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            statusText: HTTPResponse.statusText(for: status),
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: data
        )
    }

    public static func notFound(_ msg: String) -> HTTPResponse {
        HTTPResponse(
            status: 404,
            statusText: "Not Found",
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: Data(#"{"error":"\#(msg)"}"#.utf8)
        )
    }

    public static func badRequest(_ msg: String) -> HTTPResponse {
        HTTPResponse(
            status: 400,
            statusText: "Bad Request",
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: Data(#"{"error":"\#(msg)"}"#.utf8)
        )
    }

    public static func serverError(_ msg: String) -> HTTPResponse {
        HTTPResponse(
            status: 500,
            statusText: "Internal Server Error",
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: Data(#"{"error":"\#(msg)"}"#.utf8)
        )
    }

    public static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

// MARK: - Connection plumbing

/// Hashable wrapper so we can stuff `NWConnection` into a `Set`.
private final class ConnectionBox: Hashable, @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    init(connection: NWConnection) {
        self.connection = connection
    }
    static func == (lhs: ConnectionBox, rhs: ConnectionBox) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Streaming response handle for SSE / chunked output.
public final class StreamingResponseSink: @unchecked Sendable {
    fileprivate let connection: NWConnection
    private var headersSent = false

    fileprivate init(connection: NWConnection) {
        self.connection = connection
    }

    /// Write initial SSE headers (called by HTTPServer right before
    /// handing control to the streaming handler).
    func writeInitialHeaders() async {
        guard !headersSent else { return }
        headersSent = true
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: close\r
        X-Accel-Buffering: no\r
        \r

        """
        await ConnectionIO.write(connection: connection, data: head.data(using: .utf8) ?? Data())
    }

    /// Send one SSE frame. Caller provides `event:` name and `data:` body.
    public func send(event: String?, data: String) async {
        var frame = ""
        if let event {
            frame += "event: \(event)\n"
        }
        // SSE spec: each line of data prefixed with "data: ".
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            frame += "data: \(line)\n"
        }
        frame += "\n"
        await ConnectionIO.write(connection: connection, data: frame.data(using: .utf8) ?? Data())
    }

    /// Send the SSE keepalive comment `: ping\n\n`.
    public func sendHeartbeat() async {
        await ConnectionIO.write(connection: connection, data: ": ping\n\n".data(using: .utf8) ?? Data())
    }

    /// True iff the underlying TCP connection is still ready.
    public var isOpen: Bool {
        switch connection.state {
        case .ready, .preparing, .setup:
            return true
        default:
            return false
        }
    }
}

/// Static helpers wrapping `NWConnection` send/receive in `async` form.
enum ConnectionIO {

    static func readUpTo(connection: NWConnection, max: Int, headerOnly: Bool) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let buffer = MutableDataBox()
            @Sendable func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                    let current = buffer.data
                    if let error {
                        _ = error
                        cont.resume(returning: current.isEmpty ? nil : current)
                        return
                    }
                    if let data, !data.isEmpty {
                        buffer.append(data)
                    }
                    let snapshot = buffer.data
                    // Check for end-of-headers and break early if we've
                    // received \r\n\r\n + (optional content-length worth
                    // of body). Heuristic: most bridge requests are tiny
                    // and arrive in one TCP segment.
                    if let crlf = snapshot.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                        let headerEnd = crlf.upperBound
                        if let contentLength = ConnectionIO.contentLength(in: snapshot[..<headerEnd]) {
                            let need = headerEnd + contentLength
                            if snapshot.count >= need {
                                cont.resume(returning: snapshot)
                                return
                            }
                        } else {
                            // No body declared. Done.
                            cont.resume(returning: snapshot)
                            return
                        }
                    }
                    if isComplete {
                        cont.resume(returning: snapshot.isEmpty ? nil : snapshot)
                        return
                    }
                    if snapshot.count >= max {
                        cont.resume(returning: snapshot)
                        return
                    }
                    pump()
                }
            }
            pump()
        }
    }

    static func write(connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                cont.resume()
            })
        }
    }

    static func contentLength(in head: Data) -> Int? {
        guard let s = String(data: head, encoding: .utf8) else { return nil }
        for line in s.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let part = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(part)
            }
        }
        return nil
    }
}

/// Mutable byte-buffer wrapper that's safe to capture across the
/// `@Sendable` `pump()` boundary. The actual data races aren't possible
/// — NWConnection fires its receive completion serially on its private
/// dispatch queue — but Swift 6 strict concurrency can't see that, so
/// we box the buffer behind a class with an NSLock.
private final class MutableDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return _data
    }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _data.append(chunk)
    }
}

/// Tiny one-shot async/throwing continuation used to bridge
/// `NWListener.stateUpdateHandler` (sync) to `async start()`.
final class OneShotContinuation<T: Sendable, E: Swift.Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<T, Swift.Error>?

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if resumed {
                lock.unlock()
                c.resume(throwing: CancellationError())
                return
            }
            continuation = c
            lock.unlock()
        }
    }

    func resume(returning value: T) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Swift.Error) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}
