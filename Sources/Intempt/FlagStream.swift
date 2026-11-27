import Foundation

/// Callbacks of one `/flags/stream` connection. Each fires at most once per connection except
/// `onMessage`; `onClose` is not called when the SDK closed the connection itself.
struct StreamHandlers {
    let onOpen: () -> Void
    let onMessage: (_ event: String, _ data: String) -> Void
    let onClose: () -> Void
}

struct StreamHandle {
    let close: () -> Void
}

/// The one SSE connection to `/flags/stream` (F15, contract C2), ported from intempt-node
/// `src/flag-stream.ts`: reconnects with a backoff of 1 s doubling to 60 s, reset by a
/// successful open. `close()` is final; `pause()` is not, the next `start()` reconnects.
final class FlagStream {

    static let backoffStart: TimeInterval = 1
    static let backoffMax: TimeInterval = 60
    static let changedEvent = "flags_changed"

    private let open: (StreamHandlers) -> StreamHandle
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let onChange: ([String]) -> Void
    private let onState: (Bool) -> Void

    private let lock = NSLock()
    private var generation = 0
    /// The generation of the live connection. A callback from any other generation is ignored, so
    /// a late close from a replaced connection cannot tear down its successor.
    private var active: Int?
    private var handle: StreamHandle?
    private var timer: Int?
    private var delay = FlagStream.backoffStart
    private var _connected = false
    private var closed = false

    init(
        open: @escaping (StreamHandlers) -> StreamHandle,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        onChange: @escaping ([String]) -> Void,
        onState: @escaping (Bool) -> Void
    ) {
        self.open = open
        self.schedule = schedule
        self.onChange = onChange
        self.onState = onState
    }

    var connected: Bool { locked { _connected } }

    func start() {
        let go: Bool = locked { !closed && active == nil && timer == nil }
        if go { connect() }
    }

    func close() {
        locked { closed = true }
        disconnect()
    }

    func pause() {
        disconnect()
    }

    private func disconnect() {
        let (h, was): (StreamHandle?, Bool) = locked {
            defer {
                handle = nil
                active = nil
                timer = nil
                _connected = false
            }
            return (handle, _connected)
        }
        h?.close()
        if was { onState(false) }
    }

    private func connect() {
        let gen: Int = locked {
            generation += 1
            active = generation
            return generation
        }
        let h = open(
            StreamHandlers(
                onOpen: { [weak self] in self?.opened(gen) },
                onMessage: { [weak self] event, data in self?.message(gen, event, data) },
                onClose: { [weak self] in self?.ended(gen) }))
        let keep: Bool = locked {
            guard active == gen else { return false }
            handle = h
            return true
        }
        if !keep { h.close() }
    }

    private func opened(_ gen: Int) {
        let changed: Bool = locked {
            guard active == gen else { return false }
            delay = FlagStream.backoffStart
            defer { _connected = true }
            return !_connected
        }
        if changed { onState(true) }
    }

    private func message(_ gen: Int, _ event: String, _ data: String) {
        let current: Bool = locked { active == gen }
        guard current, event == FlagStream.changedEvent else { return }
        onChange(FlagStream.keys(of: data))
    }

    private func ended(_ gen: Int) {
        let next: (was: Bool, wait: TimeInterval, token: Int)? = locked {
            guard active == gen else { return nil }
            let was = _connected
            active = nil
            handle = nil
            _connected = false
            guard !closed else { return (was, 0, -1) }
            generation += 1
            timer = generation
            let wait = delay
            delay = min(delay * 2, FlagStream.backoffMax)
            return (was, wait, generation)
        }
        guard let next else { return }
        if next.was { onState(false) }
        guard next.token >= 0 else { return }
        let token = next.token
        schedule(next.wait) { [weak self] in self?.fire(token) }
    }

    private func fire(_ token: Int) {
        let go: Bool = locked {
            guard timer == token, !closed else { return false }
            timer = nil
            return true
        }
        if go { connect() }
    }

    /// `[]` means "drop every entry": a malformed event cannot be trusted to name its keys.
    static func keys(of data: String) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
            let keys = object["keys"] as? [Any]
        else { return [] }
        let strings = keys.compactMap { $0 as? String }
        return strings.count == keys.count ? strings : []
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Server-sent events framing (WHATWG §9.2), the subset `/flags/stream` uses: `event:` and
/// `data:` fields, a blank line dispatching, comment lines (the server's heartbeat) ignored.
/// Works on bytes, so a UTF-8 sequence split across two network chunks is not mangled.
struct SSEParser {
    private var buffer = Data()
    private var event = ""
    private var data: [String] = []

    mutating func feed(_ chunk: Data) -> [(event: String, data: String)] {
        buffer.append(chunk)
        var out: [(event: String, data: String)] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                if !data.isEmpty {
                    out.append((event.isEmpty ? "message" : event, data.joined(separator: "\n")))
                }
                event = ""
                data = []
            } else if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                data.append(String(value))
            }
        }
        return out
    }
}
