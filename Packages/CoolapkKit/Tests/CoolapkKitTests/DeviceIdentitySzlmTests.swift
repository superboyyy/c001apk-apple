import XCTest
@testable import CoolapkKit

final class DeviceIdentitySzlmTests: XCTestCase {
    func testOfficialDeviceIdentityValidationAndParsing() throws {
        let sample = "\u{FEFF}设备ID: unused\r\nShuzlmID： synthetic_official_identity_0123456789 \r\nAndroidID: unused\r\nUUID: unused"
        XCTAssertEqual(try OfficialDeviceIdentity.parse(sample), "synthetic_official_identity_0123456789")

        XCTAssertEqual(OfficialDeviceIdentity.validate("  DUautoIdent0000000000000000000000001  "),
                       "DUautoIdent0000000000000000000000001")
        XCTAssertNil(OfficialDeviceIdentity.validate("0000000000000000"))
        XCTAssertNil(OfficialDeviceIdentity.validate("short"))
        XCTAssertNil(OfficialDeviceIdentity.validate("has space 12345678"))

        // 不接受 OAID / AndroidID / UUID 替代，也不接受缺失或重复字段、null/undefined、过长文本。
        let rejected = [
            "AndroidID: 1234567890abcdef\nUUID: 12345678-1234-1234-1234-1234567890ab",
            "ShuzlmID: first_valid_id_1234\nShuzlmID: second_valid_id_5678",
            "ShuzlmID: null",
            "ShuzlmID: UNDEFINED",
            "ShuzlmID: 0000000000000000",
            "ShuzlmID: ",
            String(repeating: "a", count: 32_769),
        ]
        for input in rejected {
            XCTAssertThrowsError(try OfficialDeviceIdentity.parse(input)) { error in
                let message = (error as? OfficialDeviceIdentityError)?.message ?? ""
                XCTAssertFalse(message.isEmpty)
                XCTAssertFalse(message.contains("first_valid_id"), "错误文案不得回显粘贴内容")
            }
        }
    }

    func testImportAndApplyOnlyReplaceFirstDeviceSlot() throws {
        let originalPlain = "synthetic-install-identity; ; ; 02:11:22:33:44:55; TestMaker; TestBrand; TestModel; TestBuild; null"
        var identity = ClientIdentity(
            manufacturer: "TestMaker",
            brand: "TestBrand",
            model: "TestModel",
            buildNumber: "TestBuild",
            deviceCode: ClientIdentity.encodeDevice(originalPlain)
        )

        let imported = try identity.importOfficialDeviceIdentity(
            "设备ID: unused\nShuzlmID: synthetic_official_identity_0123456789\nAndroidID: unused"
        )
        XCTAssertEqual(imported, "synthetic_official_identity_0123456789")
        XCTAssertEqual(identity.szlmID, "synthetic_official_identity_0123456789")
        XCTAssertTrue(identity.hasSzlmID)

        let fields = try XCTUnwrap(ClientIdentity.decodeDevice(identity.deviceCode))
        XCTAssertEqual(
            fields.joined(separator: ";"),
            "synthetic_official_identity_0123456789; ; ; 02:11:22:33:44:55; TestMaker; TestBrand; TestModel; TestBuild; null"
        )

        // 修改协议参数或刷新设备码时保留数盟 ID。
        identity.model = "Pixel 9"
        identity.refreshDeviceCode()
        let refreshed = try XCTUnwrap(ClientIdentity.decodeDevice(identity.deviceCode))
        XCTAssertEqual(refreshed[0], "synthetic_official_identity_0123456789")
        XCTAssertEqual(refreshed[3], " 02:11:22:33:44:55")
        XCTAssertEqual(refreshed[6], " Pixel 9")

        // 重新生成设备参数默认清除数盟 ID；传 preservingSzlmID 时保留。
        identity.regenerateDeviceCode(preservingSzlmID: true)
        XCTAssertEqual(identity.szlmID, "synthetic_official_identity_0123456789")
        XCTAssertEqual(ClientIdentity.decodeDevice(identity.deviceCode)?[0], "synthetic_official_identity_0123456789")

        identity.regenerateDeviceCode()
        XCTAssertEqual(identity.szlmID, "")
        XCTAssertTrue(ClientIdentity.decodeDevice(identity.deviceCode)?[0].hasPrefix("ca_") == true)
    }

    func testCorruptDeviceCodeOrInvalidSzlmIDLeavesIdentityUntouched() throws {
        var identity = ClientIdentity()
        identity.deviceCode = "broken"
        XCTAssertThrowsError(try identity.applySzlmID("synthetic_official_identity_0123456789"))
        XCTAssertEqual(identity.deviceCode, "broken")
        XCTAssertEqual(identity.szlmID, "")

        var valid = ClientIdentity()
        try valid.applySzlmID("DUautoIdent0000000000000000000000001")
        let savedCode = valid.deviceCode
        XCTAssertThrowsError(try valid.applySzlmID("0000000000000000000000000000000000"))
        XCTAssertEqual(valid.szlmID, "DUautoIdent0000000000000000000000001")
        XCTAssertEqual(valid.deviceCode, savedCode)
    }

    func testLegacyClientIdentityJSONDecodesWithoutSzlmIDField() throws {
        let legacyJSON = #"""
        {
          "versionName": "16.2.0",
          "versionCode": "2604201",
          "apiVersion": "16",
          "manufacturer": "Google",
          "brand": "google",
          "model": "Pixel 7",
          "buildNumber": "TQ3A.230805.001",
          "sdkInt": "33",
          "androidVersion": "13",
          "deviceCode": "syntheticCode"
        }
        """#
        let decoded = try JSONDecoder().decode(ClientIdentity.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.deviceCode, "syntheticCode")
        XCTAssertEqual(decoded.szlmID, "")
        XCTAssertFalse(decoded.hasSzlmID)
    }
}
