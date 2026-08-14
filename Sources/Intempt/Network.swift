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
//    - Completion-handler based, matching upstream: bridging to async/await
//      would lose the serial-queue mutual exclusion that keeps concurrent
//      flushes from interleaving.
//
import Foundation

/// The outcome of one request, with retryability decided here rather than
/// left to the caller to infer.
enum HTTPOutcome: Equatable {
    case success(Data?)
    case retryable(status: Int, retryAfter: TimeInterval?)
    case terminal(status: Int)
    case transport(String)

    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

protocol URLSessionProtocol: AnyObject {
    func dataTask(
        with request: URLRequest,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask
}

extension URLSession: URLSessionProtocol {}

final class Network {

    private let session: URLSessionProtocol
    private let host: String

    init(session: URLSessionProtocol = URLSession.shared, host: String = APIConstants.host) {
        self.session = session
        self.host = host
    }

    /// Builds the request the wire contract expects. Exposed so tests can
    /// assert URL, headers and body without performing IO.
    func makeRequest(
        endpoint: Endpoint,
        credentials: IntemptCredentials,
        body: [String: Any]
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
        // Content-Length is deliberately NOT set: URLSession owns that header
        // and setting it manually is unsupported.
        return request
    }

    func send(_ request: URLRequest, completion: @escaping (HTTPOutcome) -> Void) {
        session.dataTask(with: request) { data, response, error in
            completion(Self.classify(data: data, response: response, error: error))
        }.resume()
    }

    /// Exhaustive classification. `error != nil` alone is not a failure test —
    /// under URLSession an HTTP 500 arrives with a nil error.
    static func classify(data: Data?, response: URLResponse?, error: Error?) -> HTTPOutcome {
        if let error {
            return .transport(error.localizedDescription)
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
            return .terminal(status: http.statusCode)
        }
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
