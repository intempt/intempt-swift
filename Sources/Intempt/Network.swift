//
//  Network.swift
//  Intempt
//
//  Adapted from mixpanel-swift's Network.swift
//  (https://github.com/mixpanel/mixpanel-swift)
//  Copyright © 2016 Mixpanel. All rights reserved.
//  Licensed under the Apache License, Version 2.0.
//
//  Modifications by Intempt Technologies, Inc. (Apache License 2.0, §4(b)):
//    - Intempt's URL shape (org/project/source-scoped) and Basic auth.
//    - Status classification is explicit and exhaustive. The old Obj-C SDK
//      branched on `error != nil`, and under NSURLSession that is nil for
//      401/403/429/500 — so every server error was treated as success and
//      triggered the destructive delete (audit F-34).
//    - Honours Retry-After.
//    - Splits URL errors raised before the request is written (`.transport`)
//      from those that may follow it (`.unanswered`), so event delivery keeps
//      only what the server never saw (INT-7436, ruling R5).
//    - Completion-handler based, matching upstream: bridging to async/await
//      would lose the serial-queue mutual exclusion that keeps concurrent
//      flushes from interleaving.
//    - A per-request timeout for render-path reads, and the `/flags/stream`
//      server-sent-events connection (`openStream`).
//
import Foundation

/// The outcome of one request, with retryability decided here rather than
/// left to the caller to infer.
enum HTTPOutcome: Equatable {
    case success(Data?)
    case retryable(status: Int, retryAfter: TimeInterval?)
    /// Carries the response body so the caller can surface the server's own
    /// message (`{"errors":[{"message":…}]}`) instead of a bare status code.
    case terminal(status: Int, body: Data?)
    /// Never reached the server (offline, DNS, refused). Nothing was received, so the batch is
    /// kept for the next flush.
    case transport(String)
    /// Sent but never answered, a timeout above all. The server may hold the batch already, so it
    /// is not resent: a resend risks a duplicate (round-2 CONTRACT S1.4).
    case unanswered(String)

    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

/// Narrower than `dataTask(with:completionHandler:)` on purpose: returning a
/// `URLSessionDataTask` would force every test double to subclass a Foundation
/// class whose initialisers are unavailable. The SDK only ever creates a task
/// and resumes it, so that is the whole contract.
protocol URLSessionProtocol: AnyObject {
    func perform(
        _ request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    )

    /// A long-lived GET whose body arrives as server-sent events. Part of the session contract so
    /// a test double never lets a test open a real connection.
    func openStream(_ request: URLRequest, handlers: StreamHandlers) -> StreamHandle
}

extension URLSession: URLSessionProtocol {
    func perform(
        _ request: URLRequest,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        dataTask(with: request, completionHandler: completion).resume()
    }

    /// Runs on a session of its own: a delegate is what delivers the body in chunks, and a
    /// session's delegate is fixed at creation, so `self` (usually `.shared`) cannot carry it.
    func openStream(_ request: URLRequest, handlers: StreamHandlers) -> StreamHandle {
        SSEConnection.open(request, handlers: handlers)
    }
}

final class Network {

    private let session: URLSessionProtocol
    private let host: String

    init(session: URLSessionProtocol = URLSession.shared, host: String = APIConstants.rootHost) {
        self.session = session
        self.host = host
    }

    /// Builds the request the wire contract expects. Exposed so tests can
    /// assert URL, headers and body without performing IO.
    /// - Parameter timeout: seconds; nil keeps URLSession's default. Flag and choose reads pass
    ///   2 s (S11, D19): they block a render, and a late answer is worth less than the default.
    func makeRequest(
        endpoint: Endpoint,
        credentials: IntemptCredentials,
        body: [String: Any],
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard let url = endpoint.url(host: host) else {
            throw IntemptError.missingConfiguration(field: "endpoint URL")
        }
        guard let data = JSONHandler.encodeAPIData(body) else {
            throw IntemptError.encodingFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("intempt-swift/\(Intempt.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        if let timeout { request.timeoutInterval = timeout }
        // Content-Length is deliberately NOT set: URLSession owns that header
        // and setting it manually is unsupported.
        return request
    }

    /// `GET` with the same authentication as every other route. `timeoutInterval` is the idle
    /// limit between chunks: the server sends a heartbeat every 15 s, so 45 s without one is a
    /// dead connection.
    func openStream(
        endpoint: Endpoint,
        credentials: IntemptCredentials,
        handlers: StreamHandlers
    ) -> StreamHandle {
        guard let url = endpoint.url(host: host) else {
            handlers.onClose()
            return StreamHandle {}
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Network.streamIdleTimeout
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("intempt-swift/\(Intempt.sdkVersion)", forHTTPHeaderField: "User-Agent")
        return session.openStream(request, handlers: handlers)
    }

    static let streamIdleTimeout: TimeInterval = 45

    func send(_ request: URLRequest, completion: @escaping (HTTPOutcome) -> Void) {
        session.perform(request) { data, response, error in
            completion(Self.classify(data: data, response: response, error: error))
        }
    }

    /// Exhaustive classification. `error != nil` alone is not a failure test —
    /// under URLSession an HTTP 500 arrives with a nil error.
    static func classify(data: Data?, response: URLResponse?, error: Error?) -> HTTPOutcome {
        if let error {
            return neverReachedServer(error)
                ? .transport(error.localizedDescription)
                : .unanswered(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .transport("no HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            return .success(data)
        case let s where APIConstants.retryableStatuses.contains(s):
            return .retryable(status: s, retryAfter: retryAfter(from: http))
        default:
            // 401/403 (bad credentials), 402 (analytics capped), 400/422
            // (malformed) — retrying cannot help.
            return .terminal(status: http.statusCode, body: data)
        }
    }

    /// URL errors raised before a byte of the request could leave the device (ruling R5). Anything
    /// else may have been received, so it is `.unanswered`, not `.transport`; the maybe-reached
    /// list and the reasoning are in docs/CONTRACT.md "Never reached versus maybe reached".
    static let neverReachedCodes: Set<Int> = [
        // Offline, or the radio may not be used.
        NSURLErrorNotConnectedToInternet,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
        // DNS, refused, unreachable: no connection was ever open.
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorCannotConnectToHost,
        // TLS handshake: the request is written only after the handshake succeeds.
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
        // Refused by URLSession itself before any connection.
        NSURLErrorAppTransportSecurityRequiresSecureConnection,
        NSURLErrorBadURL,
        NSURLErrorUnsupportedURL,
        NSURLErrorCannotLoadFromNetwork,
    ]

    static func neverReachedServer(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && neverReachedCodes.contains(ns.code)
    }

    /// Honours the server's own backoff instruction, in both the delta-seconds
    /// and HTTP-date forms.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}
