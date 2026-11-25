import XCTest
@testable import CoolapkKit

final class MultipartFormTests: XCTestCase {
    func testBoundaryUsesFixedPrefixAndTenDigits() {
        for _ in 0..<50 {
            let boundary = MultipartForm.makeBoundary()
            XCTAssertNotNil(boundary.range(of: "^--dio-boundary-[0-9]{10}$", options: .regularExpression), boundary)
        }
        XCTAssertEqual(MultipartForm(boundary: "b").contentType, "multipart/form-data; boundary=b")
    }

    func testTextFieldsAreEncodedInOrder() {
        let form = MultipartForm(fields: [("message", "你好 [doge]\n第二行"), ("message_pic", "")], boundary: "--dio-boundary-0000000001")
        let expected = "----dio-boundary-0000000001\r\n"
            + "content-disposition: form-data; name=\"message\"\r\n\r\n"
            + "你好 [doge]\n第二行\r\n"
            + "----dio-boundary-0000000001\r\n"
            + "content-disposition: form-data; name=\"message_pic\"\r\n\r\n"
            + "\r\n"
            + "----dio-boundary-0000000001--\r\n"
        XCTAssertEqual(String(decoding: form.encoded(), as: UTF8.self), expected)
    }

    func testFieldNamesAreEscaped() {
        XCTAssertEqual(MultipartForm.escape("a\"b\r\nc\nd\re"), "a%22b%0D%0Ac%0D%0Ad%0D%0Ae")
        var form = MultipartForm(boundary: "x")
        form.append(name: "na\"me", value: "v")
        XCTAssertTrue(String(decoding: form.encoded(), as: UTF8.self).contains("name=\"na%22me\"\r\n\r\nv\r\n"))
    }

    func testFilePartCarriesFilenameAndType() {
        var form = MultipartForm(boundary: "x")
        form.append(name: "file", filename: "a.png", contentType: "image/png", data: Data([0x89, 0x50, 0x00, 0xFF]))
        var expected = Data("--x\r\ncontent-disposition: form-data; name=\"file\"; filename=\"a.png\"\r\ncontent-type: image/png\r\n\r\n".utf8)
        expected.append(Data([0x89, 0x50, 0x00, 0xFF]))
        expected.append(Data("\r\n--x--\r\n".utf8))
        XCTAssertEqual(form.encoded(), expected)
    }

    func testEmptyFormIsJustTheClosingBoundary() {
        XCTAssertEqual(String(decoding: MultipartForm(boundary: "x").encoded(), as: UTF8.self), "--x--\r\n")
    }
}
