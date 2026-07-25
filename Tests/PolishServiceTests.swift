import XCTest
@testable import DogballWhisper

/// Intercepts URLSession traffic so the tests never hit the network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode = 200
        var body = Data()
        var error: Error?
    }

    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestBody = request.httpBody
            ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                var data = Data()
                let size = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }

        if let error = Self.stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.stub.statusCode,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PolishServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.stub = .init()
        StubURLProtocol.lastRequestBody = nil
    }

    private func makeService(key: String? = "sk-test") -> PolishService {
        PolishService(session: session, keyProvider: { key })
    }

    private func chatResponse(_ content: String) -> Data {
        Data(#"{"choices":[{"message":{"content":"\#(content)"}}]}"#.utf8)
    }

    func testReturnsTheCleanedText() async throws {
        StubURLProtocol.stub.body = chatResponse("So the thing is.")
        let result = try await makeService().clean(
            "um so the thing is", prompt: "Clean it.", model: "anthropic/claude-haiku-4.5")
        XCTAssertEqual(result, "So the thing is.")
    }

    func testSendsThePromptModelAndTextToOpenRouter() async throws {
        StubURLProtocol.stub.body = chatResponse("ok")
        _ = try await makeService().clean("raw text", prompt: "MY PROMPT", model: "some/model")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "some/model")
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.first?["content"], "MY PROMPT")
        XCTAssertEqual(messages.last?["content"], "raw text")
        // Thinking tokens would blow the latency budget for no gain.
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    func testMissingKeyThrowsBeforeAnyRequest() async {
        do {
            _ = try await makeService(key: nil).clean("x", prompt: "p", model: "m")
            XCTFail("expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? PolishError, .missingAPIKey)
        }
        XCTAssertNil(StubURLProtocol.lastRequestBody)
    }

    func testHTTPErrorIsReportedWithItsStatusCode() async {
        StubURLProtocol.stub.statusCode = 402
        StubURLProtocol.stub.body = Data(#"{"error":"insufficient credits"}"#.utf8)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected http error")
        } catch {
            guard case let .http(code, _)? = error as? PolishError else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(code, 402)
        }
    }

    func testEmptyContentThrows() async {
        StubURLProtocol.stub.body = chatResponse("   ")
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected emptyResponse")
        } catch {
            XCTAssertEqual(error as? PolishError, .emptyResponse)
        }
    }

    func testMalformedJSONThrows() async {
        StubURLProtocol.stub.body = Data("not json".utf8)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testTransportErrorPropagates() async {
        StubURLProtocol.stub.error = URLError(.notConnectedToInternet)
        do {
            _ = try await makeService().clean("x", prompt: "p", model: "m")
            XCTFail("expected a URLError")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // Model output sometimes arrives wrapped in quotes or a fenced block.
    func testWrappingQuotesAreStripped() async throws {
        StubURLProtocol.stub.body = chatResponse("\\\"So the thing is.\\\"")
        let quoted = try await makeService().clean("x", prompt: "p", model: "m")
        XCTAssertEqual(quoted, "So the thing is.")
    }

    func testCodeFencesAreStripped() {
        XCTAssertEqual(
            PolishService.unwrap("```\nSo the thing is.\n```"), "So the thing is.")
        XCTAssertEqual(
            PolishService.unwrap("```text\nSo the thing is.\n```"), "So the thing is.")
        // Real content that merely contains backticks must survive untouched.
        XCTAssertEqual(PolishService.unwrap("Use `git status` first."), "Use `git status` first.")
    }

    // Measured against the real endpoint: google/gemini-3.5-flash answers a
    // disabled-reasoning request with 400 "Reasoning is mandatory for this
    // endpoint and cannot be disabled." A dictation must not be lost over a
    // latency optimisation, so that specific rejection triggers one retry.
    func testAMandatoryReasoningRejectionIsRecognised() {
        XCTAssertTrue(PolishService.disablingReasoningRejected(
            status: 400,
            body: #"{"error":{"message":"Reasoning is mandatory for this endpoint and cannot be disabled."}}"#))
    }

    func testOtherFailuresAreNotTreatedAsReasoningRejections() {
        XCTAssertFalse(PolishService.disablingReasoningRejected(
            status: 400, body: #"{"error":{"message":"invalid model"}}"#))
        XCTAssertFalse(PolishService.disablingReasoningRejected(
            status: 401, body: "unauthorized"))
        // Right message, wrong status: a 500 mentioning reasoning is an
        // outage, and retrying without the field will not help.
        XCTAssertFalse(PolishService.disablingReasoningRejected(
            status: 500, body: "reasoning service unavailable"))
    }
}
