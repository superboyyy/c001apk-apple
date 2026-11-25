import XCTest
@testable import CoolapkKit

final class RequestTokenTests: XCTestCase {
    private struct Vector: Decodable {
        let device: String
        let timestamp: Int
        let token: String
    }

    func testBCryptKnownVector() throws {
        // 广泛流传的 OpenBSD 测试向量。
        let hash = try BCrypt.hash(password: "", salt: "$2a$06$DCq7YPn5Rq63x1Lad4cll.")
        XCTAssertEqual(hash, "$2a$06$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s.")
    }

    /// 与 Flutter 端 `token_vectors_test.dart` 相同的固定时间向量。
    func testV3MatchesSharedVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "token_v3", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            XCTAssertEqual(try RequestToken.v3(device: vector.device, timestamp: vector.timestamp), vector.token)
        }
    }

    func testSignatureFollowsTimeAndAppCode() throws {
        let token = try RequestToken.v3(device: "synthetic-test-device", timestamp: 1_770_000_000)
        XCTAssertNotEqual(try RequestToken.v3(device: "synthetic-test-device", timestamp: 1_770_000_001), token)
        XCTAssertNotEqual(try RequestToken.v3(device: "synthetic-test-device", timestamp: 1_770_000_000, appCode: 2_604_202), token)
    }
}
