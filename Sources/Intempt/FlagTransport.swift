import Foundation

/// The URLSession side of the flag and choose reads: the only file that joins the injected
/// closures of `Flags` and `Choose` to `Network`. Kept apart so the evaluator stays free of
/// transport (F33) and is testable with closures alone.
final class FlagTransport {

    /// S11 and D19: one flag/choose timeout, 2 s, in every SDK.
    static let timeout: TimeInterval = 2

    private let network: Network
    private let credentials: IntemptCredentials
    private let orgId: String
    private let projectId: String

    init(network: Network, credentials: IntemptCredentials, orgId: String, projectId: String) {
        self.network = network
        self.credentials = credentials
        self.orgId = orgId
        self.projectId = projectId
    }

    func post(_ route: FlagRoute, _ body: [String: Any], completion: @escaping (FlagReply) -> Void) {
        post(.flags(org: orgId, project: projectId, route: route), body, completion: completion)
    }

    func postChoose(_ body: [String: Any], completion: @escaping (FlagReply) -> Void) {
        post(.chooseApi(org: orgId, project: projectId), body, completion: completion)
    }

    func openStream(_ handlers: StreamHandlers) -> StreamHandle {
        network.openStream(
            endpoint: .flags(org: orgId, project: projectId, route: .stream),
            credentials: credentials, handlers: handlers)
    }

    private func post(
        _ endpoint: Endpoint, _ body: [String: Any], completion: @escaping (FlagReply) -> Void
    ) {
        let request: URLRequest
        do {
            request = try network.makeRequest(
                endpoint: endpoint, credentials: credentials, body: body, timeout: Self.timeout)
        } catch {
            return completion(.failed(.badRequest, status: nil))
        }
        network.send(request) { completion(Self.reply(for: $0)) }
    }

    static func reply(for outcome: HTTPOutcome) -> FlagReply {
        if case .success(let data) = outcome { return .answered(data) }
        let (kind, status) = errorKind(for: outcome)
        return .failed(kind, status: status)
    }

    /// 408 is the gateway's timeout and 429 the service's capacity, so neither is the caller's
    /// malformed request: the same mapping as intempt-node, php and python.
    static func errorKind(for outcome: HTTPOutcome) -> (FlagError.Kind, Int?) {
        switch outcome {
        case .retryable(let status, _), .terminal(let status, _):
            switch status {
            case 401, 403: return (.auth, status)
            case 408: return (.timeout, status)
            case 429, 500...: return (.server, status)
            default: return (.badRequest, status)
            }
        case .unanswered: return (.timeout, nil)
        case .transport: return (.network, nil)
        case .success: return (.parse, nil)
        }
    }
}

/// One `/flags/stream` connection on a URLSession of its own, delivering the body as it arrives.
///
/// The session holds its delegate strongly until invalidated, so every way out of the connection
/// ends in `finish`, which invalidates it; otherwise each reconnect would leak a session.
final class SSEConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let handlers: StreamHandlers
    private let lock = NSLock()
    private var parser = SSEParser()
    private var finished = false
    private var session: URLSession?

    private init(handlers: StreamHandlers) {
        self.handlers = handlers
    }

    static func open(_ request: URLRequest, handlers: StreamHandlers) -> StreamHandle {
        let connection = SSEConnection(handlers: handlers)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: connection, delegateQueue: nil)
        connection.lock.lock()
        connection.session = session
        connection.lock.unlock()
        session.dataTask(with: request).resume()
        return StreamHandle { connection.finish(notify: false) }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            IntemptLogger.shared.log(
                .debug,
                "flag stream refused with \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            completionHandler(.cancel)
            return finish(notify: true)
        }
        completionHandler(.allow)
        handlers.onOpen()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let events: [(event: String, data: String)] = {
            lock.lock()
            defer { lock.unlock() }
            return finished ? [] : parser.feed(data)
        }()
        for event in events { handlers.onMessage(event.event, event.data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(notify: true)
    }

    private func finish(notify: Bool) {
        lock.lock()
        let first = !finished
        finished = true
        let session = self.session
        self.session = nil
        lock.unlock()
        guard first else { return }
        session?.invalidateAndCancel()
        if notify { handlers.onClose() }
    }
}
