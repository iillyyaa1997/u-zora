import Foundation
import os

/// Minimal Model Context Protocol server speaking JSON-RPC 2.0 over
/// `POST /mcp`. Implements just the request subset needed by MCP-host
/// clients (Claude Code, Claude Desktop, Cursor, Cline) to discover
/// and invoke uZora's five read-only tools:
///
/// - `initialize`                  → version handshake + capabilities
/// - `notifications/initialized`   → no-op ACK
/// - `tools/list`                  → enumerate tools with JSON Schema
/// - `tools/call`                  → invoke one of the 5 tools
/// - `ping`                        → liveness check
///
/// Notification stream (server-pushed tool-results) is **not** in scope
/// for Phase 4 — `uzora_subscribe` returns the SSE URL instead so the
/// caller can connect to `/stream` for live updates. The README will
/// document this delegation; Phase 6+ can switch to SSE-transport MCP
/// once the ecosystem catches up.
public struct MCPServer: Sendable {

    public let tools: MCPTools
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "mcp")

    public init(tools: MCPTools) {
        self.tools = tools
    }

    /// Server identity reported through `initialize`.
    public static let serverName = "uzora"
    public static let serverVersion = "0.1.0"
    public static let protocolVersion = "2024-11-05"

    /// HTTP handler — parses the JSON-RPC envelope, dispatches the method,
    /// returns the JSON-RPC response.
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "POST" else {
            return HTTPResponse.badRequest("MCP requires POST")
        }
        guard !request.body.isEmpty else {
            return HTTPResponse.badRequest("MCP requires JSON-RPC body")
        }

        // Accept both single envelopes and batches.
        let body = request.body
        if let first = body.first, first == UInt8(ascii: "[") {
            return await handleBatch(body)
        }
        let envelope: JSONRPCRequest
        do {
            envelope = try JSONRPCRequest.decode(from: body)
        } catch {
            return MCPServer.jsonResponse(JSONRPCResponse.error(
                id: nil,
                code: .parseError,
                message: "json decode failed: \(error)"
            ))
        }
        let response = await dispatch(envelope)
        if let response {
            return MCPServer.jsonResponse(response)
        } else {
            // Notification: spec mandates HTTP 202 with empty body.
            return HTTPResponse(status: 202, statusText: "Accepted", headers: [], body: Data())
        }
    }

    private func handleBatch(_ body: Data) async -> HTTPResponse {
        let requests: [JSONRPCRequest]
        do {
            requests = try JSONRPCRequest.decodeArray(from: body)
        } catch {
            return MCPServer.jsonResponse(JSONRPCResponse.error(
                id: nil,
                code: .parseError,
                message: "json decode failed: \(error)"
            ))
        }
        var responses: [JSONRPCResponse] = []
        for r in requests {
            if let resp = await dispatch(r) {
                responses.append(resp)
            }
        }
        if responses.isEmpty {
            return HTTPResponse(status: 202, statusText: "Accepted", headers: [], body: Data())
        }
        let data = (try? JSONRPCResponse.encodeArray(responses)) ?? Data("[]".utf8)
        return HTTPResponse.jsonData(data)
    }

    /// Dispatch one envelope. Returns nil when the envelope is a
    /// notification (no `id` → no response).
    private func dispatch(_ envelope: JSONRPCRequest) async -> JSONRPCResponse? {
        let isNotification = envelope.id == nil
        // Method routing.
        switch envelope.method {
        case "initialize":
            let result: [String: JSONValue] = [
                "protocolVersion": .string(MCPServer.protocolVersion),
                "serverInfo": .object([
                    "name": .string(MCPServer.serverName),
                    "version": .string(MCPServer.serverVersion),
                ]),
                "capabilities": .object([
                    "tools": .object([:]),
                ]),
            ]
            return JSONRPCResponse.result(id: envelope.id, result: .object(result))

        case "notifications/initialized", "initialized":
            // Pure notification, no response.
            return nil

        case "ping":
            return JSONRPCResponse.result(id: envelope.id, result: .object([:]))

        case "tools/list":
            return JSONRPCResponse.result(
                id: envelope.id,
                result: .object([
                    "tools": .array(tools.listSchemas().map { .object($0) }),
                ])
            )

        case "tools/call":
            guard case .object(let params)? = envelope.params,
                  case .string(let name)? = params["name"]
            else {
                return JSONRPCResponse.error(
                    id: envelope.id,
                    code: .invalidParams,
                    message: "tools/call requires {name, arguments}"
                )
            }
            let args: JSONValue
            if let supplied = params["arguments"] {
                args = supplied
            } else {
                args = .object([:])
            }
            do {
                let result = try await tools.invoke(name: name, arguments: args)
                return JSONRPCResponse.result(id: envelope.id, result: result)
            } catch let error as MCPTools.InvokeError {
                return JSONRPCResponse.error(
                    id: envelope.id,
                    code: error.code,
                    message: error.message
                )
            } catch {
                return JSONRPCResponse.error(
                    id: envelope.id,
                    code: .internalError,
                    message: "\(error)"
                )
            }

        default:
            if isNotification {
                return nil
            }
            return JSONRPCResponse.error(
                id: envelope.id,
                code: .methodNotFound,
                message: "method \(envelope.method) not found"
            )
        }
    }

    static func jsonResponse(_ response: JSONRPCResponse) -> HTTPResponse {
        do {
            let data = try response.encode()
            return HTTPResponse.jsonData(data)
        } catch {
            return HTTPResponse.serverError("response encode failed: \(error)")
        }
    }
}

// MARK: - JSON-RPC 2.0 envelopes

public struct JSONRPCRequest: Sendable {
    public let jsonrpc: String
    public let id: JSONValue?       // nil = notification
    public let method: String
    public let params: JSONValue?

    public static func decode(from data: Data) throws -> JSONRPCRequest {
        let parsed = try JSONValue.decode(data)
        guard case .object(let fields) = parsed else {
            throw DecodeError.malformed
        }
        guard case .string(let version)? = fields["jsonrpc"] else {
            throw DecodeError.malformed
        }
        guard case .string(let method)? = fields["method"] else {
            throw DecodeError.malformed
        }
        return JSONRPCRequest(
            jsonrpc: version,
            id: fields["id"],
            method: method,
            params: fields["params"]
        )
    }

    public static func decodeArray(from data: Data) throws -> [JSONRPCRequest] {
        let parsed = try JSONValue.decode(data)
        guard case .array(let arr) = parsed else { throw DecodeError.malformed }
        return try arr.map { value in
            guard case .object(let fields) = value else { throw DecodeError.malformed }
            guard case .string(let version)? = fields["jsonrpc"] else { throw DecodeError.malformed }
            guard case .string(let method)? = fields["method"] else { throw DecodeError.malformed }
            return JSONRPCRequest(jsonrpc: version, id: fields["id"], method: method, params: fields["params"])
        }
    }

    public enum DecodeError: Swift.Error { case malformed }
}

public struct JSONRPCResponse: Sendable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let result: JSONValue?
    public let error: ErrorPayload?

    public struct ErrorPayload: Sendable {
        public let code: Int
        public let message: String
        public let data: JSONValue?
    }

    public static func result(id: JSONValue?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id ?? .null, result: result, error: nil)
    }

    public static func error(id: JSONValue?, code: ErrorCode, message: String) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: "2.0",
            id: id ?? .null,
            result: nil,
            error: ErrorPayload(code: code.rawValue, message: message, data: nil)
        )
    }

    public func encode() throws -> Data {
        var obj: [String: JSONValue] = ["jsonrpc": .string(jsonrpc)]
        if let id { obj["id"] = id }
        if let result { obj["result"] = result }
        if let error {
            var e: [String: JSONValue] = [
                "code": .int(error.code),
                "message": .string(error.message),
            ]
            if let data = error.data { e["data"] = data }
            obj["error"] = .object(e)
        }
        return try JSONValue.object(obj).encode()
    }

    public static func encodeArray(_ responses: [JSONRPCResponse]) throws -> Data {
        var values: [JSONValue] = []
        for r in responses {
            var obj: [String: JSONValue] = ["jsonrpc": .string(r.jsonrpc)]
            if let id = r.id { obj["id"] = id }
            if let result = r.result { obj["result"] = result }
            if let error = r.error {
                var e: [String: JSONValue] = [
                    "code": .int(error.code),
                    "message": .string(error.message),
                ]
                if let data = error.data { e["data"] = data }
                obj["error"] = .object(e)
            }
            values.append(.object(obj))
        }
        return try JSONValue.array(values).encode()
    }
}

/// JSON-RPC 2.0 error codes used by uZora's MCP server.
public enum ErrorCode: Int, Sendable {
    case parseError      = -32700
    case invalidRequest  = -32600
    case methodNotFound  = -32601
    case invalidParams   = -32602
    case internalError   = -32603
    // Server-defined range (-32000..-32099) used by MCPTools.
    case toolNotFound    = -32000
    case toolFailure     = -32001
}

// MARK: - Lightweight JSON value type
//
// We hand-roll a JSONValue rather than `Any` so the MCP server stays
// fully Sendable / Codable-friendly. The MCP tool result shape is
// idiomatic JSON (objects, arrays, strings, numbers, bools, null) and
// this enum captures all six.

public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode() throws -> Data {
        let any = JSONValue.toJSONObject(self)
        return try JSONSerialization.data(
            withJSONObject: any,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return fromJSONObject(any)
    }

    private static func toJSONObject(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { toJSONObject($0) }
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, val) in o { d[k] = toJSONObject(val) }
            return d
        }
    }

    private static func fromJSONObject(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let b = any as? Bool, type(of: any) == type(of: NSNumber(value: true)) {
            // Bool boxed as NSNumber — detect through dynamic type check.
            // Actually `NSNumber` and Bool both arrive here. Easiest test:
            // CFGetTypeID.
            if CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID() {
                return .bool(b)
            }
        }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            // Distinguish int vs double by checking objCType.
            let t = String(cString: n.objCType)
            if t == "q" || t == "i" || t == "l" || t == "s" || t == "Q" || t == "I" || t == "L" || t == "S" {
                return .int(n.intValue)
            }
            return .double(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map { fromJSONObject($0) }) }
        if let d = any as? [String: Any] {
            var o: [String: JSONValue] = [:]
            for (k, v) in d { o[k] = fromJSONObject(v) }
            return .object(o)
        }
        return .null
    }
}
