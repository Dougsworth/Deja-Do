import XCTest
@testable import DejaDoCore

final class WebhookTests: XCTestCase {
    let token = "0123456789abcdef0123456789abcdef"
    let invoice = WebhookAPI.TaskInfo(id: UUID(), name: "Send invoice", variables: ["client", "amount"])
    let report = WebhookAPI.TaskInfo(id: UUID(), name: "Export report", variables: [])

    func raw(_ method: String, _ target: String, headers: [String: String] = [:], body: String = "") -> Data {
        var h = headers
        if !body.isEmpty { h["Content-Length"] = "\(body.utf8.count)" }
        let lines = ["\(method) \(target) HTTP/1.1", "Host: 127.0.0.1"] + h.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    func request(_ method: String, _ target: String, auth: Bool = true, body: String = "") -> HTTPRequest {
        let data = raw(method, target, headers: auth ? ["Authorization": "Bearer \(token)"] : [:], body: body)
        guard case .request(let r) = HTTPRequest.parse(data) else { XCTFail("didn't parse"); return HTTPRequest(method: "", path: "") }
        return r
    }

    func route(_ r: HTTPRequest, busy: Bool = false) -> WebhookAPI.Route {
        WebhookAPI.route(r, token: token, tasks: [invoice, report], busy: busy)
    }

    func status(_ route: WebhookAPI.Route) -> Int? {
        if case .respond(let r) = route { return r.status }
        return nil
    }

    func body(_ route: WebhookAPI.Route) -> [String: Any] {
        guard case .respond(let r) = route else { return [:] }
        return (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    // MARK: Parsing

    func testParsesHeadersQueryAndBody() {
        let data = raw("post", "/run?task=Export%20report&wait=1", headers: ["X-DejaDo-Token": "abc"], body: "{\"a\":1}")
        guard case .request(let r) = HTTPRequest.parse(data) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/run")
        XCTAssertEqual(r.query["task"], "Export report")
        XCTAssertEqual(r.headers["x-dejado-token"], "abc")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"a\":1}")
    }

    func testWaitsForTheWholeBody() {
        let full = raw("POST", "/run", body: "{\"task\":\"Export report\"}")
        XCTAssertEqual(HTTPRequest.parse(full.prefix(20)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(full.prefix(full.count - 3)), .incomplete)
        if case .request = HTTPRequest.parse(full) {} else { XCTFail() }
    }

    func testRefusesHugeAndChunkedBodies() {
        XCTAssertEqual(HTTPRequest.parse(raw("POST", "/run", headers: ["Content-Length": "5000000"])), .tooLarge)
        if case .bad = HTTPRequest.parse(raw("POST", "/run", headers: ["Transfer-Encoding": "chunked"])) {} else { XCTFail() }
        if case .bad = HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)) {} else { XCTFail() }
    }

    func testResponseIsWellFormed() {
        let text = String(decoding: HTTPResponse.json(202, ["ok": true]).serialized, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.hasSuffix("{\"ok\":true}"))
    }

    // MARK: Auth

    func testHealthNeedsNoToken() {
        XCTAssertEqual(status(route(request("GET", "/health", auth: false))), 200)
    }

    func testEverythingElseNeedsTheToken() {
        XCTAssertEqual(status(route(request("GET", "/tasks", auth: false))), 401)
        XCTAssertEqual(status(route(request("POST", "/run", auth: false, body: "{\"task\":\"Export report\"}"))), 401)
        var wrong = request("GET", "/tasks", auth: false)
        wrong.headers["authorization"] = "Bearer " + String(token.reversed())
        XCTAssertEqual(status(route(wrong)), 401)
        var other = request("GET", "/tasks", auth: false)
        other.headers["x-dejado-token"] = token
        XCTAssertEqual(status(route(other)), 200)
    }

    func testAShortTokenNeverAuthorises() {
        var r = request("GET", "/tasks", auth: false)
        r.headers["authorization"] = "Bearer "
        XCTAssertFalse(WebhookAPI.authorized(r, token: ""))
        r.headers["authorization"] = "Bearer abc"
        XCTAssertFalse(WebhookAPI.authorized(r, token: "abc"))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(WebhookAPI.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(WebhookAPI.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(WebhookAPI.constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(WebhookAPI.constantTimeEqual("", "a"))
    }

    func testNewTokensAreLongAndDifferent() {
        let a = WebhookAPI.newToken(), b = WebhookAPI.newToken()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
    }

    // MARK: Routes

    func testListsTasksWithTheirVariables() {
        let tasks = body(route(request("GET", "/tasks")))["tasks"] as? [[String: Any]]
        XCTAssertEqual(tasks?.count, 2)
        XCTAssertEqual(tasks?.first?["name"] as? String, "Send invoice")
        XCTAssertEqual(tasks?.first?["variables"] as? [String], ["client", "amount"])
    }

    func testRunByNameWithValues() {
        let id = UUID()
        let r = WebhookAPI.route(request("POST", "/run", body: "{\"task\":\"send INVOICE\",\"values\":{\"client\":\"Ana\",\"amount\":120},\"callback\":\"https://n8n.example.com/webhook/x\"}"),
                                 token: token, tasks: [invoice, report], busy: false, newID: { id })
        guard case .run(let run, let runID) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(runID, id)
        XCTAssertEqual(run.task, invoice)
        XCTAssertEqual(run.values, ["client": "Ana", "amount": "120"])
        XCTAssertEqual(run.callback?.host, "n8n.example.com")
        XCTAssertFalse(run.wait)
    }

    func testRunByIdAndQueryOnly() {
        let r = route(request("POST", "/run?task=\(report.id.uuidString)&wait=true"))
        guard case .run(let run, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(run.task, report)
        XCTAssertTrue(run.wait)
        XCTAssertTrue(run.values.isEmpty, "wait and task aren't values")
    }

    func testMissingValuesAreNamed() {
        let r = route(request("POST", "/run", body: "{\"task\":\"Send invoice\",\"values\":{\"client\":\"Ana\"}}"))
        XCTAssertEqual(status(r), 400)
        XCTAssertEqual(body(r)["missing"] as? [String], ["amount"])
    }

    func testUnknownTaskListsTheRealOnes() {
        let r = route(request("POST", "/run", body: "{\"task\":\"Nope\"}"))
        XCTAssertEqual(status(r), 404)
        XCTAssertEqual(body(r)["tasks"] as? [String], ["Send invoice", "Export report"])
    }

    func testBadInputIsRejectedClearly() {
        XCTAssertEqual(status(route(request("POST", "/run", body: "not json"))), 400)
        XCTAssertEqual(status(route(request("POST", "/run", body: "{}"))), 400)
        XCTAssertEqual(status(route(request("POST", "/run", body: "{\"task\":\"Export report\",\"values\":[1]}"))), 400)
        XCTAssertEqual(status(route(request("POST", "/run", body: "{\"task\":\"Send invoice\",\"values\":{\"client\":{},\"amount\":1}}"))), 400)
        XCTAssertEqual(status(route(request("POST", "/run", body: "{\"task\":\"Export report\",\"callback\":\"file:///etc/passwd\"}"))), 400)
        XCTAssertEqual(status(route(request("POST", "/run", body: "{\"task\":\"Export report\",\"callback\":\"javascript:alert(1)\"}"))), 400)
        XCTAssertEqual(status(route(request("GET", "/run"))), 405)
        XCTAssertEqual(status(route(request("GET", "/elsewhere"))), 404)
    }

    func testBusyIsAConflict() {
        let r = route(request("POST", "/run", body: "{\"task\":\"Export report\"}"), busy: true)
        XCTAssertEqual(status(r), 409)
        XCTAssertEqual(body(r)["retryAfter"] as? Int, 10)
    }

    func testRunStatusRoute() {
        let id = UUID()
        XCTAssertEqual(route(request("GET", "/runs/\(id.uuidString)")), .status(id))
        XCTAssertEqual(status(route(request("GET", "/runs/nope"))), 404)
    }

    // MARK: Results

    func testFinishedRunJSONHasNoTypedText() {
        var run = WebhookRun(id: UUID(), taskID: invoice.id, taskName: invoice.name, started: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(run.json["status"] as? String, "running")
        let record = RunRecord(started: Date(timeIntervalSince1970: 1000), duration: 4.24, outcome: "Done.", succeeded: true,
                               steps: [.init(index: 0, summary: "Type into “Client”", note: nil, ran: true),
                                       .init(index: 1, summary: "Click button “Send”", note: "Screen matched", ran: true)])
        run.finish(record, outcome: .finished)
        let j = run.json
        XCTAssertEqual(j["status"] as? String, "succeeded")
        XCTAssertEqual(j["seconds"] as? Double, 4.2)
        XCTAssertEqual((j["steps"] as? [[String: Any]])?.last?["index"] as? Int, 2)
        XCTAssertEqual(j["mayHaveChangedThings"] as? Bool, false)
        XCTAssertFalse(String(decoding: run.jsonData, as: UTF8.self).contains("Ana"))
    }

    func testStoppedAfterARiskyStepSaysSo() {
        var run = WebhookRun(id: UUID(), taskID: invoice.id, taskName: invoice.name)
        let record = RunRecord(started: Date(), duration: 1, outcome: "Stopped at step 3.", succeeded: false, steps: [])
        run.finish(record, outcome: .stoppedAfterChanges(atStep: 2, lastRiskyStep: 1))
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.mayHaveChangedThings)
        var cancelled = WebhookRun(id: UUID(), taskID: invoice.id, taskName: invoice.name)
        cancelled.finish(record, outcome: .cancelled(atStep: 0, riskyDone: false))
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testRunStoreKeepsTheNewest() {
        let store = WebhookRuns(keep: 3)
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { store.put(WebhookRun(id: id, taskID: UUID(), taskName: "t")) }
        XCTAssertNil(store.get(ids[0]))
        XCTAssertNil(store.get(ids[1]))
        XCTAssertNotNil(store.get(ids[4]))
        var updated = store.get(ids[4])!
        updated.status = .succeeded
        store.put(updated)
        XCTAssertEqual(store.get(ids[4])?.status, .succeeded)
        XCTAssertNotNil(store.get(ids[2]), "updating doesn't push others out")
    }
}
