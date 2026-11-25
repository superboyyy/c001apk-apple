import Foundation

/// multipart/form-data 请求体编码。分隔符和字段头的写法与上游使用的 Dio 一致。
struct MultipartForm {
    /// 一个表单段；`filename` 为空时是普通文本字段。
    struct Part {
        var name: String
        var data: Data
        var filename: String?
        var contentType: String?
    }

    let boundary: String
    private(set) var parts: [Part] = []

    init(boundary: String = MultipartForm.makeBoundary()) {
        self.boundary = boundary
    }

    init(fields: [(String, String)], boundary: String = MultipartForm.makeBoundary()) {
        self.boundary = boundary
        for (name, value) in fields { append(name: name, value: value) }
    }

    /// 形如 `--dio-boundary-0123456789`：固定前缀加 10 位随机数字。
    static func makeBoundary() -> String {
        let digits = String(UInt32.random(in: 0...UInt32.max))
        return "--dio-boundary-" + String(repeating: "0", count: max(0, 10 - digits.count)) + digits
    }

    /// 请求头 `Content-Type` 的取值。
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func append(name: String, value: String) {
        parts.append(Part(name: name, data: Data(value.utf8)))
    }

    mutating func append(name: String, filename: String, contentType: String, data: Data) {
        parts.append(Part(name: name, data: data, filename: filename, contentType: contentType))
    }

    /// 字段名、文件名里的换行和引号按浏览器的规则转义。
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "%0D%0A")
            .replacingOccurrences(of: "\r", with: "%0D%0A")
            .replacingOccurrences(of: "\n", with: "%0D%0A")
            .replacingOccurrences(of: "\"", with: "%22")
    }

    func encoded() -> Data {
        var body = Data()
        for part in parts {
            var header = "--\(boundary)\r\ncontent-disposition: form-data; name=\"\(MultipartForm.escape(part.name))\""
            if let filename = part.filename {
                header += "; filename=\"\(MultipartForm.escape(filename))\""
                header += "\r\ncontent-type: \(part.contentType ?? "application/octet-stream")"
            }
            body.append(Data((header + "\r\n\r\n").utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
