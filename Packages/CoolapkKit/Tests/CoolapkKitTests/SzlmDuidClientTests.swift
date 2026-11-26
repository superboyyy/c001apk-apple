import XCTest
@testable import CoolapkKit

final class SzlmDuidClientTests: XCTestCase {
    private static let poolKey = Array(#"xp7j@&!v5]2k#+3z{n9$q^r%[8f1*d4e:c>0l?m/6)yb-=w}"#.utf8)
    private static let seed = "0123456789abcdef0123456789abcdef"
    private static let syntheticID = "DUsynthetic0000000000000000000000000AB"

    private func makeResponse(_ object: [String: Any], compressed: Bool = true) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        let payload = compressed ? try SzlmDuidClient.zlibCompress(json, level: 6) : json
        return SzlmDuidClient.xor(payload)
    }

    private func decodeReport(_ body: Data) throws -> [String: JSON] {
        let plain = SzlmDuidClient.xor(body)
        let inflated = try SzlmDuidClient.zlibDecompress(plain, maxBytes: SzlmDuidClient.maxResponseBytes)
        let parsed = try XCTUnwrap(JSON.parse(inflated)?.object)
        return parsed
    }

    func testFieldCodecMatchesUpstreamVectors() {
        let encodeVectors: [Int: String] = [
            0: "g8f7e6d5c4b3:291",
            168: "r<q=p>o?n@mAEBDC",
            281: " }{RPNLJ~|zQOMKI",
            399: #"[]_ac-/1\^`bd.02"#,
        ]
        for (p, expected) in encodeVectors {
            XCTAssertEqual(SzlmFieldCodec.encode("0123456789abcdef", p: p), expected, "p=\(p)")
        }

        let anchorVectors: [Int: String] = [
            0: "8f7e6d5c4b3:291",
            168: "r<q=p>o?n@mAEBD",
            281: " |zQOMKI}{RPNLJ",
            399: #"[]_bd.02\^`c-/1"#,
        ]
        let checksumVectors: [Int: String] = [
            0: "3B712DE",
            168: "3FE78A8",
            281: "4A213D3",
            399: "FE709C6",
        ]
        for p in anchorVectors.keys {
            XCTAssertEqual(SzlmFieldCodec.anchor("0123456789abcdef", p: p), anchorVectors[p], "anchor p=\(p)")
            XCTAssertEqual(SzlmFieldCodec.checksum("0123456789abcdef", p: p), checksumVectors[p], "checksum p=\(p)")
        }
    }

    func testTimestampParameterUsesUnpaddedFractionalTail() {
        XCTAssertEqual(SzlmFieldCodec.parameter("1700000004.7"), 47)
        XCTAssertEqual(SzlmFieldCodec.parameter("1700000000.1"), 1)
        XCTAssertEqual(SzlmFieldCodec.parameter("1700000000.123456281"), 281)
    }

    func testEncodeReportEscapesSlashesAndProducesValidZlib() throws {
        // p = 399 会让 foO / dLH 中同时出现 `/` 和 `\`，验证 JSON 转义与 zlib 头部。
        let report = try SzlmDuidClient.buildReport(seed: Self.seed, ts: "1700000000.399")
        let encoded = try SzlmDuidClient.encodeReport(report)
        let xored = SzlmDuidClient.xor(encoded)
        XCTAssertGreaterThanOrEqual(xored.count, 2)
        XCTAssertEqual(xored[0], 0x78)
        XCTAssertEqual(((Int(xored[0]) << 8) + Int(xored[1])) % 31, 0)

        let rawJSON = try String(
            decoding: SzlmDuidClient.zlibDecompress(xored, maxBytes: SzlmDuidClient.maxResponseBytes),
            as: UTF8.self
        )
        XCTAssertTrue(rawJSON.contains(#"\/"#), "JSON 中应将 `/` 转义为 `\\/`")
        XCTAssertTrue(rawJSON.contains(#""SAN":33"#))
        let decoded = try decodeReport(encoded)
        XCTAssertEqual(decoded["foO"]?.string, #"[]_bd.02\^`c-/1"#)
    }

    func testDecodeIDAcceptsCompressedAndPlainResponses() throws {
        for compressed in [false, true] {
            for err in [0 as Any, "0" as Any] {
                XCTAssertEqual(
                    SzlmDuidClient.decodeID(try makeResponse(["err": err, "n_a": Self.syntheticID], compressed: compressed)),
                    Self.syntheticID
                )
                XCTAssertEqual(
                    SzlmDuidClient.decodeID(try makeResponse(["err": err, "cdd": Self.syntheticID], compressed: compressed)),
                    Self.syntheticID
                )
                XCTAssertEqual(
                    SzlmDuidClient.decodeID(try makeResponse(["err": err, "n_a": "", "cdd": Self.syntheticID], compressed: compressed)),
                    Self.syntheticID
                )
            }
        }
    }

    func testDecodeIDRejectsErrorsExplicitRejectionAndMalformedResponses() throws {
        let invalidPayloads: [[String: Any]] = [
            ["err": "1", "n_a": Self.syntheticID],
            ["err": false, "n_a": Self.syntheticID],
            ["n_a": Self.syntheticID],
            ["err": "0", "n_a": "0000000000000000", "cdd": Self.syntheticID],
            ["err": "0", "n_a": 123],
            ["err": "0", "cdd": "short"],
        ]
        for body in invalidPayloads {
            XCTAssertNil(SzlmDuidClient.decodeID(try makeResponse(body)))
        }
        XCTAssertNil(SzlmDuidClient.decodeID(Data("<html>blocked</html>".utf8)))
        XCTAssertNil(SzlmDuidClient.decodeID(Data()))
        XCTAssertNil(
            SzlmDuidClient.decodeID(
                try makeResponse(["err": "0", "n_a": Self.syntheticID, "padding": String(repeating: "x", count: 100_000)])
            )
        )
    }

    func testFetchGeneratesConsistentAnchorsWithFreshTimestampsAndRequestIDs() async throws {
        let state = LockedBox<(urls: [URL], reports: [[String: JSON]])>(([], []))
        for step in 0..<2 {
            let counter = LockedBox(step * 100 + 1)
            let id = try await SzlmDuidClient.fetch(
                seed: Self.seed,
                post: { url, body in
                    let report = try self.decodeReport(body)
                    state.withLock {
                        $0.urls.append(url)
                        $0.reports.append(report)
                    }
                    return try self.makeResponse(["err": "0", "n_a": Self.syntheticID])
                },
                randomNumber: { upper in
                    counter.withLock { value in
                        let current = value
                        value += 7
                        return current % upper
                    }
                },
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
            XCTAssertEqual(id, Self.syntheticID)
        }

        let recorded = state.withLock { $0 }
        XCTAssertEqual(recorded.urls.count, 2)
        let firstR = URLComponents(url: recorded.urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "r" }?.value
        let secondR = URLComponents(url: recorded.urls[1], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "r" }?.value
        XCTAssertNotNil(firstR)
        XCTAssertNotEqual(firstR, secondR)

        XCTAssertNotEqual(recorded.reports[0]["2cO"], recorded.reports[1]["2cO"])
        XCTAssertEqual(recorded.reports[0]["P1J"], recorded.reports[1]["P1J"])
        XCTAssertEqual(recorded.reports[0]["P1J"], recorded.reports[0]["AYk"])

        for report in recorded.reports {
            let ts = try XCTUnwrap(report["2cO"]?.string)
            let p = SzlmFieldCodec.parameter(ts)
            XCTAssertEqual(report["foO"]?.string, SzlmFieldCodec.anchor(String(Self.seed.prefix(16)), p: p))
            XCTAssertEqual(report["sfOo"]?.string, SzlmFieldCodec.checksum(String(Self.seed.prefix(16)), p: p))
            XCTAssertNil(report["6yY"])
            XCTAssertNil(report["Q23"])
        }
    }

    func testFetchTransportFailureFallsBackOnceWithSameBody() async throws {
        let recorded = LockedBox<(hosts: [String], bodies: [Data])>(([], []))
        let id = try await SzlmDuidClient.fetch(
            seed: Self.seed,
            post: { url, body in
                let callIndex = recorded.withLock { state -> Int in
                    state.hosts.append(url.host ?? "")
                    state.bodies.append(body)
                    return state.hosts.count
                }
                if callIndex == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                return try self.makeResponse(["err": 0, "cdd": Self.syntheticID])
            }
        )
        XCTAssertEqual(id, Self.syntheticID)
        let snapshot = recorded.withLock { $0 }
        XCTAssertEqual(snapshot.hosts, [SzlmDuidClient.host, SzlmDuidClient.fallbackHost])
        XCTAssertEqual(snapshot.bodies.first, snapshot.bodies.last)
    }

    func testFetchExplicitRejectionDoesNotRetryFallbackHost() async throws {
        let calls = LockedBox(0)
        do {
            _ = try await SzlmDuidClient.fetch(
                seed: Self.seed,
                post: { _, _ in
                    calls.withLock { $0 += 1 }
                    return try self.makeResponse(["err": "0", "n_a": "0000000000000000"])
                }
            )
            XCTFail("服务端全 0 拒绝应直接失败")
        } catch is SzlmDuidError {
            XCTAssertEqual(calls.withLock { $0 }, 1)
        }
    }

    func testFetchNetworkErrorsDoNotLeakRawDiagnostics() async throws {
        struct SecretError: Error, LocalizedError {
            var errorDescription: String? { "private diagnostic with secret-token" }
        }
        let calls = LockedBox(0)
        do {
            _ = try await SzlmDuidClient.fetch(
                seed: Self.seed,
                post: { _, _ in
                    calls.withLock { $0 += 1 }
                    throw SecretError()
                }
            )
            XCTFail("双域名网络错误应抛出 SzlmDuidError")
        } catch let error as SzlmDuidError {
            XCTAssertFalse(error.message.contains("secret"))
            XCTAssertEqual(calls.withLock { $0 }, 2)
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
