import Foundation

// MARK: - HTTP, just enough

/// A parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    public enum Parse: Equatable {
        /// More bytes are needed.
        case incomplete
        case bad(String)
        case tooLarge
        case request(HTTPRequest)
    }

    public static let maxBody = 1_000_000

    /// Parses a request once all of it has arrived.
    public static func parse(_ raw: Data) -> Parse {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return raw.count > 64_000 ? .tooLarge : .incomplete
        }
        let head = String(decoding: raw[raw.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard first.count >= 2 else { return .bad("bad request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        var length = 0
        if let l = headers["content-length"] {
            guard let n = Int(l), n >= 0 else { return .bad("bad content length") }
            length = n
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { return .bad("chunked bodies aren't supported") }
        guard length <= maxBody else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard raw.count - (bodyStart - raw.startIndex) >= length else { return .incomplete }
        let body = Data(raw[bodyStart..<(bodyStart + length)])

        let target = String(first[1])
        let comps = URLComponents(string: "http://localhost" + (target.hasPrefix("/") ? target : "/" + target))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(HTTPRequest(method: String(first[0]).uppercased(), path: comps?.path ?? target,
                                    query: query, headers: headers, body: body))
    }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status; self.body = body; self.contentType = contentType
    }

    public static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    public static func error(_ status: Int, _ message: String, extra: [String: Any] = [:]) -> HTTPResponse {
        json(status, extra.merging(["error": message]) { a, _ in a })
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    public var serialized: Data {
        var out = Data("HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}

// MARK: - The Deja Do API

/// What another tool (n8n, Make, a script, an agent) may ask Deja Do to do.
///
///     GET  /health                 no token needed: {"ok": true}
///     GET  /tasks                  the tasks and the variables each needs
///     POST /run                    {"task": "<name or id>", "values": {...}, "callback": "https://…", "wait": false}
///     GET  /runs/<id>              how a run went
///
/// Every call but /health needs the token, as `Authorization: Bearer <token>`
/// or an `X-DejaDo-Token` header. Typed values go into the task and are
/// never echoed back or kept in the run result.
public enum WebhookAPI {
    public struct TaskInfo: Equatable {
        public var id: UUID
        public var name: String
        public var variables: [String]

        public init(id: UUID, name: String, variables: [String]) {
            self.id = id; self.name = name; self.variables = variables
        }
    }

    public struct RunRequest: Equatable {
        public var task: TaskInfo
        public var values: [String: String]
        public var callback: URL?
        public var wait: Bool
    }

    public enum Route: Equatable {
        case respond(HTTPResponse)
        /// Start this run. `runID` is already chosen so the reply can name it.
        case run(RunRequest, runID: UUID)
        case status(UUID)
    }

    /// Decides what a request means. Starting runs and looking them up is left to the caller.
    public static func route(_ r: HTTPRequest, token: String, tasks: [TaskInfo], busy: Bool,
                             newID: () -> UUID = UUID.init) -> Route {
        if r.path == "/health" || r.path == "/" {
            return .respond(.json(200, ["ok": true, "app": "Deja Do"]))
        }
        guard authorized(r, token: token) else {
            return .respond(.error(401, "Missing or wrong token. Send it as Authorization: Bearer <token>."))
        }
        switch (r.method, r.path) {
        case ("GET", "/tasks"):
            return .respond(.json(200, ["tasks": tasks.map { ["id": $0.id.uuidString, "name": $0.name, "variables": $0.variables] }]))
        case ("POST", "/run"):
            return runRoute(r, tasks: tasks, busy: busy, newID: newID)
        case ("GET", let p) where p.hasPrefix("/runs/"):
            guard let id = UUID(uuidString: String(p.dropFirst("/runs/".count))) else {
                return .respond(.error(404, "No run with that id."))
            }
            return .status(id)
        case (_, "/tasks"), (_, "/run"):
            return .respond(.error(405, "Use GET /tasks and POST /run."))
        default:
            return .respond(.error(404, "Unknown path. Try GET /tasks or POST /run."))
        }
    }

    static func runRoute(_ r: HTTPRequest, tasks: [TaskInfo], busy: Bool, newID: () -> UUID) -> Route {
        var object: [String: Any] = [:]
        if !r.body.isEmpty {
            guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
                return .respond(.error(400, "The body must be a JSON object."))
            }
            object = o
        }
        // Query parameters work too, for tools that can only make a simple request.
        let key = (object["task"] as? String) ?? r.query["task"]
        guard let key, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .respond(.error(400, "Say which task to run: {\"task\": \"name or id\"}."))
        }
        guard let task = find(key, in: tasks) else {
            return .respond(.error(404, "No task called “\(key)”.", extra: ["tasks": tasks.map(\.name)]))
        }
        var values: [String: String] = [:]
        if let v = object["values"] {
            guard let dict = v as? [String: Any] else { return .respond(.error(400, "\"values\" must be an object of names to text.")) }
            for (k, x) in dict {
                switch x {
                case let s as String: values[k] = s
                case let n as NSNumber: values[k] = n.stringValue
                default: return .respond(.error(400, "The value for “\(k)” must be text or a number."))
                }
            }
        }
        for (k, v) in r.query where k != "task" && k != "wait" && k != "callback" { values[k] = values[k] ?? v }
        let missing = Variables.missing(task.variables, in: Array(values.keys))
        guard missing.isEmpty else {
            return .respond(.error(400, "Missing values for " + missing.map { "{{\($0)}}" }.joined(separator: ", ") + ".",
                                   extra: ["missing": missing]))
        }
        var callback: URL?
        if let c = (object["callback"] as? String) ?? r.query["callback"], !c.isEmpty {
            guard let u = URL(string: c), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil else {
                return .respond(.error(400, "\"callback\" must be an http or https address."))
            }
            callback = u
        }
        guard !busy else {
            return .respond(.error(409, "Deja Do is already running or recording something. Try again shortly.", extra: ["retryAfter": 10]))
        }
        let wait = (object["wait"] as? Bool) ?? ["1", "true", "yes"].contains((r.query["wait"] ?? "").lowercased())
        return .run(RunRequest(task: task, values: values, callback: callback, wait: wait), runID: newID())
    }

    static func find(_ key: String, in tasks: [TaskInfo]) -> TaskInfo? {
        if let id = UUID(uuidString: key), let t = tasks.first(where: { $0.id == id }) { return t }
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        return tasks.first { $0.name.lowercased() == k }
    }

    public static func authorized(_ r: HTTPRequest, token: String) -> Bool {
        guard token.count >= 16 else { return false }
        var given = r.headers["x-dejado-token"]
        if given == nil, let auth = r.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            given = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard let given else { return false }
        return constantTimeEqual(given, token)
    }

    /// Compares without returning early, so the time taken says nothing about the token.
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// A fresh random token, 32 bytes as hex.
    public static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}

// MARK: - Run results

/// How a run started from outside is going, as sent back to the caller and to the callback.
public struct WebhookRun: Equatable {
    public enum Status: String { case running, succeeded, failed, cancelled }

    public var id: UUID
    public var taskID: UUID
    public var taskName: String
    public var status: Status
    public var started: Date
    public var finished: Date?
    public var message: String?
    /// True when a step that sends, saves or deletes may have run before a stop.
    public var mayHaveChangedThings: Bool
    public var steps: [RunRecord.StepRun]
    /// What read steps found on screen, by name.
    public var values: [String: String] = [:]

    public init(id: UUID, taskID: UUID, taskName: String, status: Status = .running, started: Date = Date(),
                finished: Date? = nil, message: String? = nil, mayHaveChangedThings: Bool = false,
                steps: [RunRecord.StepRun] = []) {
        self.id = id; self.taskID = taskID; self.taskName = taskName; self.status = status; self.started = started
        self.finished = finished; self.message = message; self.mayHaveChangedThings = mayHaveChangedThings; self.steps = steps
    }

    /// Fills in the result from a finished run's record.
    public mutating func finish(_ record: RunRecord, outcome: RunOutcome, values: [String: String] = [:]) {
        self.values = values
        finished = record.started.addingTimeInterval(record.duration)
        message = record.outcome
        steps = record.steps
        mayHaveChangedThings = outcome.mayRepeatChanges
        switch outcome {
        case .finished: status = .succeeded
        case .cancelled: status = .cancelled
        default: status = record.succeeded ? .succeeded : .failed
        }
    }

    public var json: [String: Any] {
        let iso = ISO8601DateFormatter()
        var o: [String: Any] = [
            "runId": id.uuidString, "taskId": taskID.uuidString, "task": taskName, "status": status.rawValue,
            "started": iso.string(from: started), "mayHaveChangedThings": mayHaveChangedThings,
            "steps": steps.map { s -> [String: Any] in
                var x: [String: Any] = ["index": s.index + 1, "summary": s.summary, "ran": s.ran]
                if let n = s.note { x["note"] = n }
                return x
            }
        ]
        if let finished {
            o["finished"] = iso.string(from: finished)
            o["seconds"] = (finished.timeIntervalSince(started) * 10).rounded() / 10
        }
        if let message { o["message"] = message }
        if !values.isEmpty { o["values"] = values }
        return o
    }

    public var jsonData: Data {
        (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// Keeps the last runs started from outside, so callers can look them up.
public final class WebhookRuns: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [UUID: WebhookRun] = [:]
    private var order: [UUID] = []
    public let keep: Int

    public init(keep: Int = 100) { self.keep = keep }

    public func put(_ r: WebhookRun) {
        lock.lock(); defer { lock.unlock() }
        if runs[r.id] == nil { order.append(r.id) }
        runs[r.id] = r
        while order.count > keep { runs[order.removeFirst()] = nil }
    }

    public func get(_ id: UUID) -> WebhookRun? {
        lock.lock(); defer { lock.unlock() }
        return runs[id]
    }
}
