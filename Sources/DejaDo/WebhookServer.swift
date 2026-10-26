import Foundation
import Network
import CryptoKit
@preconcurrency import DejaDoCore

/// Lets other tools on this Mac start tasks: n8n or Node-RED running locally,
/// a shell script, Shortcuts, an agent. Listens on 127.0.0.1 only, so nothing
/// on the network can reach it, and every call but /health needs the token.
///
/// A cloud service like Zapier can't reach 127.0.0.1. For those, a relay
/// (the Deja Do server, or a tunnel the person sets up) forwards to this.
final class WebhookServer: @unchecked Sendable {
    /// What the server needs from the app, called on the main thread.
    struct Hooks {
        var tasks: () -> [WebhookAPI.TaskInfo]
        var busy: () -> Bool
        /// Starts the run and calls `done` on the main thread when it ends. Returns false if it couldn't start.
        var start: (_ run: WebhookAPI.RunRequest, _ runID: UUID, _ done: @escaping (RunRecord, RunOutcome, [String: String]) -> Void) -> Bool
    }

    static let defaultPort: UInt16 = 7357
    /// How long a caller asking to wait is kept waiting before getting the run id instead.
    static let maxWait: TimeInterval = 15 * 60

    let runs = WebhookRuns()
    private var listener: NWListener?
    private var token = ""
    private var hooks: Hooks?
    private let queue = DispatchQueue(label: "dejado.webhooks")
    private(set) var port: UInt16 = 0
    private(set) var lastError: String?

    var isRunning: Bool { listener != nil && port != 0 }

    func start(port: UInt16, token: String, hooks: Hooks) -> Bool {
        stop()
        self.token = token
        self.hooks = hooks
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
            let l = try NWListener(using: params)
            let ready = DispatchSemaphore(value: 0)
            var ok = false
            l.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    ok = true
                    ready.signal()
                case .failed(let e):
                    self?.lastError = e.localizedDescription
                    ready.signal()
                case .cancelled:
                    ready.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: queue)
            listener = l
            _ = ready.wait(timeout: .now() + 3)
            if !ok { stop(); lastError = lastError ?? "Port \(port) is in use." }
            return ok
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: Connections

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { c.cancel(); return }
                if let data { buffer.append(data) }
                if error != nil { c.cancel(); return }
                switch HTTPRequest.parse(buffer) {
                case .incomplete:
                    if done { c.cancel() } else { readMore() }
                case .tooLarge:
                    self.send(.error(413, "Too large."), on: c)
                case .bad(let why):
                    self.send(.error(400, why), on: c)
                case .request(let r):
                    self.handle(r, on: c)
                }
            }
        }
        readMore()
    }

    private func send(_ r: HTTPResponse, on c: NWConnection) {
        c.send(content: r.serialized, completion: .contentProcessed { _ in c.cancel() })
    }

    private func handle(_ r: HTTPRequest, on c: NWConnection) {
        // A browser page can't read the reply without CORS, but it could still
        // send a request. Requests from a web page carry an Origin; refuse them.
        if r.headers["origin"] != nil {
            send(.error(401, "Requests from web pages aren't accepted."), on: c)
            return
        }
        // A page can point its own domain name at 127.0.0.1 (DNS rebinding). Only local names are let in.
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host) else {
            send(.error(401, "Use http://127.0.0.1:\(port)."), on: c)
            return
        }
        DispatchQueue.main.async { [self] in
            guard let hooks else { send(.error(503, "Not ready."), on: c); return }
            switch WebhookAPI.route(r, token: token, tasks: hooks.tasks(), busy: hooks.busy()) {
            case .respond(let response):
                send(response, on: c)
            case .status(let id):
                if let run = runs.get(id) { send(.json(200, run.json), on: c) }
                else { send(.error(404, "No run with that id. Only the last 100 are kept, and none survive a restart."), on: c) }
            case .run(let request, let runID):
                start(request, runID: runID, hooks: hooks, connection: c)
            }
        }
    }

    private func start(_ request: WebhookAPI.RunRequest, runID: UUID, hooks: Hooks, connection c: NWConnection) {
        var run = WebhookRun(id: runID, taskID: request.task.id, taskName: request.task.name)
        runs.put(run)
        let waiter = Waiter(connection: request.wait ? c : nil)
        let started = hooks.start(request, runID) { [weak self] record, outcome, values in
            guard let self else { return }
            run.finish(record, outcome: outcome, values: values)
            self.runs.put(run)
            if let callback = request.callback { self.deliver(run, to: callback) }
            if let w = waiter.take() { self.send(.json(200, run.json), on: w) }
        }
        guard started else {
            run.status = .failed
            run.message = "Deja Do couldn't start the run. It may be missing a permission."
            runs.put(run)
            send(.json(503, run.json), on: c)
            return
        }
        if request.wait {
            // Don't hold a caller forever: after the limit, answer with where to look.
            queue.asyncAfter(deadline: .now() + Self.maxWait) { [weak self] in
                guard let self, let w = waiter.take() else { return }
                self.send(.json(202, self.runs.get(runID)?.json ?? run.json), on: w)
            }
        } else {
            send(.json(202, run.json), on: c)
        }
    }

    /// Holds a waiting connection so it's answered exactly once.
    final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: NWConnection?
        init(connection: NWConnection?) { self.connection = connection }
        func take() -> NWConnection? {
            lock.lock(); defer { lock.unlock() }
            let c = connection
            connection = nil
            return c
        }
    }

    // MARK: Callbacks

    /// Posts the result to the caller's address, signed with the token so the
    /// receiver can check it came from this Mac. Tries three times.
    private func deliver(_ run: WebhookRun, to url: URL, attempt: Int = 0) {
        let body = run.jsonData
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(run.id.uuidString, forHTTPHeaderField: "X-DejaDo-Run")
        req.setValue(Self.signature(body, token: token), forHTTPHeaderField: "X-DejaDo-Signature")
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error != nil || !(200..<300).contains(code), attempt < 2 else { return }
            self?.queue.asyncAfter(deadline: .now() + Double(2 << attempt)) {
                self?.deliver(run, to: url, attempt: attempt + 1)
            }
        }.resume()
    }

    /// `sha256=<hex>` of an HMAC over the body, keyed by the token.
    static func signature(_ body: Data, token: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(token.utf8)))
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}
