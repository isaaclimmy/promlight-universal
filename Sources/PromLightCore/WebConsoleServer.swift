import Foundation
import Network

enum WebConsoleHTTPParseError: Error, Equatable, CustomStringConvertible {
    case headerTooLarge
    case bodyTooLarge
    case malformedRequest(String)
    case unsupportedTransferEncoding

    var description: String {
        switch self {
        case .headerTooLarge: return "HTTP request headers are too large."
        case .bodyTooLarge: return "HTTP request body is too large."
        case .malformedRequest(let detail): return "Malformed HTTP request: \(detail)"
        case .unsupportedTransferEncoding: return "Chunked request bodies are not supported."
        }
    }
}

struct WebConsoleHTTPRequest: Equatable {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    var body: Data
}

enum WebConsoleHTTPRequestParser {
    static let maximumHeaderBytes = 16 * 1_024
    static let maximumBodyBytes = 256 * 1_024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Returns `nil` while a valid request is incomplete.
    static func parse(_ data: Data) throws -> WebConsoleHTTPRequest? {
        guard let delimiter = data.range(of: headerTerminator) else {
            if data.count > maximumHeaderBytes { throw WebConsoleHTTPParseError.headerTooLarge }
            return nil
        }
        guard delimiter.lowerBound <= maximumHeaderBytes else {
            throw WebConsoleHTTPParseError.headerTooLarge
        }

        let headerData = data.subdata(in: data.startIndex..<delimiter.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw WebConsoleHTTPParseError.malformedRequest("headers must be UTF-8")
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw WebConsoleHTTPParseError.malformedRequest("missing request line")
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestParts.count == 3 else {
            throw WebConsoleHTTPParseError.malformedRequest("invalid request line")
        }
        guard requestParts[1].hasPrefix("/") else {
            throw WebConsoleHTTPParseError.malformedRequest("request target must be an origin path")
        }
        guard requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
            throw WebConsoleHTTPParseError.malformedRequest("unsupported HTTP version")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw WebConsoleHTTPParseError.malformedRequest("invalid header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw WebConsoleHTTPParseError.malformedRequest("empty header name")
            }
            if name == "content-length", headers[name] != nil {
                throw WebConsoleHTTPParseError.malformedRequest("duplicate content length")
            }
            headers[name] = value
        }

        if let transferEncoding = headers["transfer-encoding"], transferEncoding.lowercased() != "identity" {
            throw WebConsoleHTTPParseError.unsupportedTransferEncoding
        }

        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsedLength = Int(rawLength), parsedLength >= 0 else {
                throw WebConsoleHTTPParseError.malformedRequest("invalid content length")
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyBytes else { throw WebConsoleHTTPParseError.bodyTooLarge }

        let bodyStart = delimiter.upperBound
        let requestEnd = bodyStart + contentLength
        guard data.count >= requestEnd else { return nil }

        return WebConsoleHTTPRequest(
            method: requestParts[0].uppercased(),
            target: requestParts[1],
            version: requestParts[2],
            headers: headers,
            body: data.subdata(in: bodyStart..<requestEnd)
        )
    }
}

struct WebConsoleHTTPResponse {
    var statusCode: Int
    var reasonPhrase: String
    var headers: [String: String]
    var body: Data

    static func html(_ html: String) -> WebConsoleHTTPResponse {
        WebConsoleHTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": "default-src 'none'; base-uri 'none'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'",
                "Permissions-Policy": "camera=(), geolocation=(), microphone=()",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "X-Frame-Options": "DENY",
            ],
            body: Data(html.utf8)
        )
    }

    static func json<T: Encodable>(
        _ value: T,
        statusCode: Int = 200,
        reasonPhrase: String = "OK",
        additionalHeaders: [String: String] = [:]
    ) -> WebConsoleHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data(#"{"error":"Response encoding failed."}"#.utf8)
        var headers = additionalHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        return WebConsoleHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: headers,
            body: data
        )
    }

    func serialized() -> Data {
        var finalHeaders = headers
        finalHeaders["Cache-Control"] = "no-store"
        finalHeaders["Connection"] = "close"
        finalHeaders["Content-Length"] = String(body.count)

        var head = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        for key in finalHeaders.keys.sorted() {
            if let value = finalHeaders[key] { head += "\(key): \(value)\r\n" }
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

private struct WebConsoleCommandRequest: Decodable {
    var command: String
}

private struct WebConsoleErrorResponse: Encodable {
    var error: String
}

enum WebConsoleHostValidator {
    static func allows(_ request: WebConsoleHTTPRequest, port: UInt16) -> Bool {
        guard request.version == "HTTP/1.1" else { return true }
        guard let host = request.headers["host"]?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }
}

struct WebConsoleHTTPRouter: Sendable {
    let statusProvider: WebConsoleStatusProvider
    let commandHandler: WebConsoleCommandHandler
    let eventHandler: WebConsoleEventHandler

    func response(for request: WebConsoleHTTPRequest) -> WebConsoleHTTPResponse {
        let path = String(request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        switch (request.method, path) {
        case ("GET", "/"):
            return .html(WebConsolePage.html)

        case ("GET", "/api/status"):
            do {
                return .json(try statusProvider())
            } catch {
                return serverError(error)
            }

        case ("POST", "/api/command"):
            guard acceptsJSON(request) else { return unsupportedMediaType() }
            do {
                let requestBody = try JSONDecoder().decode(WebConsoleCommandRequest.self, from: request.body)
                let command = requestBody.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else {
                    return badRequest("The command must not be empty.")
                }
                let result = try commandHandler(command)
                return .json(
                    result,
                    statusCode: result.accepted ? 200 : 422,
                    reasonPhrase: result.accepted ? "OK" : "Unprocessable Content"
                )
            } catch is DecodingError {
                return badRequest("The request body must be JSON with a string command field.")
            } catch {
                return serverError(error)
            }

        case ("POST", "/api/event"):
            guard acceptsJSON(request) else { return unsupportedMediaType() }
            do {
                let event = try JSONDecoder().decode(WebConsoleEvent.self, from: request.body)
                guard !event.payload.isEmpty else {
                    return badRequest("The event object must not be empty.")
                }
                let result = try eventHandler(event)
                return .json(
                    result,
                    statusCode: result.accepted ? 200 : 422,
                    reasonPhrase: result.accepted ? "OK" : "Unprocessable Content"
                )
            } catch is DecodingError {
                return badRequest("The request body must be a JSON object.")
            } catch {
                return serverError(error)
            }

        case (_, "/"), (_, "/api/status"), (_, "/api/command"), (_, "/api/event"):
            let allowed = path == "/" || path == "/api/status" ? "GET" : "POST"
            return .json(
                WebConsoleErrorResponse(error: "Method not allowed."),
                statusCode: 405,
                reasonPhrase: "Method Not Allowed",
                additionalHeaders: ["Allow": allowed]
            )

        default:
            return .json(
                WebConsoleErrorResponse(error: "Route not found."),
                statusCode: 404,
                reasonPhrase: "Not Found"
            )
        }
    }

    private func acceptsJSON(_ request: WebConsoleHTTPRequest) -> Bool {
        guard let contentType = request.headers["content-type"] else { return false }
        return contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/json"
    }

    private func badRequest(_ message: String) -> WebConsoleHTTPResponse {
        .json(
            WebConsoleErrorResponse(error: message),
            statusCode: 400,
            reasonPhrase: "Bad Request"
        )
    }

    private func unsupportedMediaType() -> WebConsoleHTTPResponse {
        .json(
            WebConsoleErrorResponse(error: "Content-Type must be application/json."),
            statusCode: 415,
            reasonPhrase: "Unsupported Media Type"
        )
    }

    private func serverError(_ error: Error) -> WebConsoleHTTPResponse {
        .json(
            WebConsoleErrorResponse(error: String(describing: error)),
            statusCode: 500,
            reasonPhrase: "Internal Server Error"
        )
    }
}

public enum WebConsoleServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

public enum WebConsoleServerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning
    case invalidPort

    public var description: String {
        switch self {
        case .alreadyRunning: return "The web console server is already running."
        case .invalidPort: return "The web console port is invalid."
        }
    }
}

/// Small local-only HTTP server for PromLight setup and control.
///
/// The listener always uses the loopback host. Its port may be changed for
/// diagnostics, without exposing the console on a LAN interface.
public final class WebConsoleServer: @unchecked Sendable {
    public typealias StatusProvider = WebConsoleStatusProvider
    public typealias CommandHandler = WebConsoleCommandHandler
    public typealias EventHandler = WebConsoleEventHandler
    public typealias StateHandler = @Sendable (WebConsoleServerState) -> Void

    public static let host = "127.0.0.1"
    public static let port: UInt16 = 7_800
    public static let url = URL(string: "http://127.0.0.1:7800/")!
    public let listenPort: UInt16
    public var consoleURL: URL { URL(string: "http://127.0.0.1:\(listenPort)/")! }

    private let router: WebConsoleHTTPRouter
    private let queue: DispatchQueue
    private let handlerQueue: DispatchQueue
    private let stateHandler: StateHandler?
    private let lock = NSLock()
    private var listener: NWListener?
    private var storedState: WebConsoleServerState = .stopped

    public init(
        statusProvider: @escaping StatusProvider,
        onCommand commandHandler: @escaping CommandHandler,
        onEvent eventHandler: @escaping EventHandler,
        port: UInt16 = WebConsoleServer.port,
        stateHandler: StateHandler? = nil,
        queue: DispatchQueue? = nil,
        handlerQueue: DispatchQueue? = nil
    ) {
        router = WebConsoleHTTPRouter(
            statusProvider: statusProvider,
            commandHandler: commandHandler,
            eventHandler: eventHandler
        )
        self.stateHandler = stateHandler
        self.listenPort = port
        self.queue = queue ?? DispatchQueue(label: "com.promlight.web-console.network", qos: .userInitiated)
        self.handlerQueue = handlerQueue ?? DispatchQueue(label: "com.promlight.web-console.handlers", qos: .userInitiated, attributes: .concurrent)
    }

    public var state: WebConsoleServerState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    public func start() throws {
        guard let networkPort = NWEndpoint.Port(rawValue: listenPort) else {
            throw WebConsoleServerError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(Self.host),
            port: networkPort
        )
        let newListener = try NWListener(using: parameters)

        lock.lock()
        guard listener == nil else {
            lock.unlock()
            newListener.cancel()
            throw WebConsoleServerError.alreadyRunning
        }
        listener = newListener
        lock.unlock()

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            switch state {
            case .ready:
                guard self.isCurrent(newListener) else { return }
                self.transition(to: .ready)
            case .failed(let error):
                guard self.removeIfCurrent(newListener) else { return }
                self.transition(to: .failed(String(describing: error)))
                newListener.cancel()
            case .cancelled:
                guard self.removeIfCurrent(newListener) else { return }
                self.transition(to: .stopped)
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        transition(to: .starting)
        newListener.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let activeListener = listener
        listener = nil
        lock.unlock()

        activeListener?.stateUpdateHandler = nil
        activeListener?.newConnectionHandler = nil
        activeListener?.cancel()
        transition(to: .stopped)
    }

    deinit {
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let content { requestData.append(content) }

            do {
                if let request = try WebConsoleHTTPRequestParser.parse(requestData) {
                    self.handlerQueue.async {
                        let response: WebConsoleHTTPResponse
                        if WebConsoleHostValidator.allows(request, port: self.listenPort) {
                            response = self.router.response(for: request)
                        } else {
                            response = .json(
                                WebConsoleErrorResponse(error: "The Host header must identify the local PromLight console."),
                                statusCode: 421,
                                reasonPhrase: "Misdirected Request"
                            )
                        }
                        self.send(response, on: connection)
                    }
                } else if isComplete {
                    self.send(
                        .json(
                            WebConsoleErrorResponse(error: "The HTTP request ended before it was complete."),
                            statusCode: 400,
                            reasonPhrase: "Bad Request"
                        ),
                        on: connection
                    )
                } else if error == nil {
                    self.receive(on: connection, accumulated: requestData)
                } else {
                    connection.cancel()
                }
            } catch WebConsoleHTTPParseError.headerTooLarge {
                self.send(
                    .json(
                        WebConsoleErrorResponse(error: "HTTP request headers are too large."),
                        statusCode: 431,
                        reasonPhrase: "Request Header Fields Too Large"
                    ),
                    on: connection
                )
            } catch WebConsoleHTTPParseError.bodyTooLarge {
                self.send(
                    .json(
                        WebConsoleErrorResponse(error: "HTTP request body is too large."),
                        statusCode: 413,
                        reasonPhrase: "Content Too Large"
                    ),
                    on: connection
                )
            } catch {
                self.send(
                    .json(
                        WebConsoleErrorResponse(error: String(describing: error)),
                        statusCode: 400,
                        reasonPhrase: "Bad Request"
                    ),
                    on: connection
                )
            }
        }
    }

    private func send(_ response: WebConsoleHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func transition(to state: WebConsoleServerState) {
        lock.lock()
        let changed = storedState != state
        storedState = state
        lock.unlock()
        if changed { stateHandler?(state) }
    }

    private func isCurrent(_ candidate: NWListener) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener === candidate
    }

    @discardableResult
    private func removeIfCurrent(_ candidate: NWListener) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard listener === candidate else { return false }
        listener = nil
        return true
    }
}
