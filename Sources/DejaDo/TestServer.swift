import Foundation
import Network

/// A small web page Deja Do serves to itself for the web self test.
///
/// Real software breaks automations in a handful of ways: a button gets
/// renamed or moved, the page loads late, a banner covers the target, the
/// button is scrolled out of view, a lookalike sits next to it, a confirm
/// dialog appears, or the result takes its time. This page can fake each of
/// those on request, and it counts how many times its form was really
/// submitted, so a test can prove "sent exactly once" rather than assume it.
final class TestServer: @unchecked Sendable {
    /// Ways the page can be broken between recording and replay.
    enum Break: String, CaseIterable {
        /// "Submit" becomes "Submit request".
        case rename
        /// "Submit" becomes "Send": a different word, so text can't carry the match.
        case relabel
        /// The fields change order and the button moves to the top right.
        case move
        /// The form only appears 2.5 seconds after the page loads.
        case delay
        /// A cookie banner covers the Submit button until "Got it" is clicked.
        case banner
        /// A tall block pushes the form below the fold.
        case offscreen
        /// A "Submit feedback" button sits right next to "Submit".
        case lookalike
        /// Every element's DOM id changes on each load.
        case idswap
        /// Submit opens a "Send this request?" dialog instead of sending.
        case confirm
        /// The thank you message takes 3 seconds to show after Submit.
        case slow
    }

    struct State: Equatable {
        var submits = 0
        var feedback = 0
        var confirms = 0
        var gotIt = 0
        var lastName = ""
        var lastEmail = ""
    }

    private let lock = NSLock()
    private var _state = State()
    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    func reset() {
        lock.lock(); _state = State(); lock.unlock()
    }

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Starts listening on 127.0.0.1 on a free port. Returns false when it couldn't.
    func start() -> Bool {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: params)
            let ready = DispatchSemaphore(value: 0)
            var ok = false
            l.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    ok = true
                    ready.signal()
                case .failed, .cancelled:
                    ready.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.start(queue: DispatchQueue(label: "dejado.testserver"))
            listener = l
            _ = ready.wait(timeout: .now() + 3)
            return ok && port != 0
        } catch {
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func url(breaks: [Break]) -> URL {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = Int(port)
        c.path = "/form"
        if !breaks.isEmpty { c.queryItems = [URLQueryItem(name: "break", value: breaks.map(\.rawValue).joined(separator: ","))] }
        return c.url!
    }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: DispatchQueue(label: "dejado.testserver.conn"))
        var buffer = Data()
        func readMore() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if error != nil { c.cancel(); return }
                if let response = self.respond(to: buffer) {
                    c.send(content: response, completion: .contentProcessed { _ in c.cancel() })
                } else if done {
                    c.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    /// Returns a full HTTP response once the request has arrived completely, else nil.
    private func respond(to raw: Data) -> Data? {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return http(400, "text/plain", "bad request") }
        let method = String(parts[0])
        let target = String(parts[1])
        var length = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            length = Int(l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        let bodyStart = headerEnd.upperBound
        guard raw.count - bodyStart >= length else { return nil }
        let body = raw[bodyStart..<(bodyStart + length)]

        let comps = URLComponents(string: "http://x" + target)
        switch (method, comps?.path ?? target) {
        case ("GET", "/form"):
            let names = comps?.queryItems?.first { $0.name == "break" }?.value ?? ""
            let breaks = Set(names.split(separator: ",").compactMap { Break(rawValue: String($0)) })
            return http(200, "text/html; charset=utf-8", page(breaks))
        case ("POST", "/event"):
            record(body)
            return http(200, "application/json", "{\"ok\":true}")
        case ("GET", "/state"):
            let s = state
            return http(200, "application/json",
                        "{\"submits\":\(s.submits),\"feedback\":\(s.feedback),\"confirms\":\(s.confirms),\"gotIt\":\(s.gotIt)}")
        default:
            return http(404, "text/plain", "not found")
        }
    }

    private func record(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let kind = json["kind"] as? String else { return }
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case "submit":
            _state.submits += 1
            _state.lastName = json["name"] as? String ?? ""
            _state.lastEmail = json["email"] as? String ?? ""
        case "feedback": _state.feedback += 1
        case "confirm": _state.confirms += 1
        case "gotit": _state.gotIt += 1
        default: break
        }
    }

    private func http(_ status: Int, _ type: String, _ body: String) -> Data {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let bytes = Data(body.utf8)
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(bytes)
        return out
    }

    // MARK: The page

    private func page(_ b: Set<Break>) -> String {
        // Plain, legible, and the same every time unless a break says otherwise.
        let submitText = b.contains(.rename) ? "Submit request" : (b.contains(.relabel) ? "Send" : "Submit")
        let ids = b.contains(.idswap)
            ? (name: "f\(Int.random(in: 10000...99999))", email: "f\(Int.random(in: 10000...99999))", submit: "b\(Int.random(in: 10000...99999))")
            : (name: "name", email: "email", submit: "submit")
        let spacer = b.contains(.offscreen) ? "<div style='height:1500px'></div>" : ""
        let hidden = b.contains(.delay) ? "hidden" : ""
        let lookalike = b.contains(.lookalike)
            ? "<button type=button id=feedback onclick=\"send('feedback')\">Submit feedback</button>" : ""
        let banner = b.contains(.banner) ? """
            <div id=banner style="position:fixed;left:0;right:0;bottom:0;background:#222;color:#fff;padding:28px 24px;font-size:17px;display:flex;justify-content:space-between;align-items:center;z-index:9">
              <span>We use cookies to make this page work.</span>
              <button type=button onclick="send('gotit');document.getElementById('banner').remove()" style="font-size:17px;padding:10px 20px">Got it</button>
            </div>
            """ : ""
        let fields = """
            <p><label for=\(ids.name)>Name</label><br><input id=\(ids.name) autocomplete=off></p>
            <p><label for=\(ids.email)>Email</label><br><input id=\(ids.email) autocomplete=off></p>
            """
        let fieldsMoved = """
            <p><label for=\(ids.email)>Email</label><br><input id=\(ids.email) autocomplete=off></p>
            <p><label for=\(ids.name)>Name</label><br><input id=\(ids.name) autocomplete=off></p>
            """
        let button = "<button type=button id=\(ids.submit) onclick=\"submit()\">\(submitText)</button>"
        let form = b.contains(.move) ? """
            <div style="display:flex;justify-content:space-between;align-items:flex-start">
              <div>\(fieldsMoved)</div>
              <div style="padding-top:8px">\(button)\(lookalike)</div>
            </div>
            """ : "\(fields)<p>\(button) \(lookalike)</p>"

        return """
        <!doctype html>
        <html><head><meta charset=utf-8><title>Deja Do test form</title>
        <style>
          body{font:17px -apple-system,Helvetica,sans-serif;color:#111;background:#fff;margin:0;padding:48px 64px;max-width:720px}
          h1{font-size:28px;font-weight:600;margin:0 0 28px}
          label{color:#444}
          input{font:inherit;padding:8px 10px;border:1px solid #bbb;border-radius:4px;width:320px}
          button{font:inherit;padding:9px 18px;border:1px solid #888;border-radius:4px;background:#f4f4f4;margin-right:12px}
          #thanks{font-size:22px;margin-top:32px}
          #dialog{position:fixed;inset:0;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center}
          #dialog div{background:#fff;padding:32px 40px;border-radius:8px;font-size:19px}
        </style></head>
        <body>
        \(spacer)
        <h1>Request access</h1>
        <div id=form \(hidden)>\(form)</div>
        <div id=thanks></div>
        \(banner)
        <script>
          const N='\(ids.name)', E='\(ids.email)';
          function post(kind, extra){ return fetch('/event',{method:'POST',body:JSON.stringify(Object.assign({kind},extra||{}))}); }
          function send(kind){ post(kind); }
          function val(id){ const el=document.getElementById(id); return el?el.value:''; }
          function thanks(name, n){
            document.getElementById('form').remove();
            const t=document.getElementById('thanks');
            t.textContent='Thanks, '+(name||'friend')+'. Request #'+n+' received.';
          }
          let count=0;
          function finish(){
            const name=val(N), email=val(E);
            count+=1;
            post('submit',{name,email});
            \(b.contains(.slow) ? "setTimeout(()=>thanks(name,count),3000);" : "thanks(name,count);")
          }
          function submit(){
            \(b.contains(.confirm) ? """
            const d=document.createElement('div'); d.id='dialog';
            d.innerHTML='<div><p>Send this request?</p><button type=button onclick="confirmIt()">Confirm</button> <button type=button onclick="document.getElementById(\\'dialog\\').remove()">Cancel</button></div>';
            document.body.appendChild(d);
            """ : "finish();")
          }
          function confirmIt(){ post('confirm'); document.getElementById('dialog').remove(); finish(); }
          \(b.contains(.delay) ? "setTimeout(()=>document.getElementById('form').removeAttribute('hidden'),2500);" : "")
        </script>
        </body></html>
        """
    }
}
