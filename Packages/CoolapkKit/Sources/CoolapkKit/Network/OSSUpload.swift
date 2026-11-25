import CryptoKit
import Foundation

/// 一张待上传的图片：文件内容加上服务端登记所需的尺寸与类型。对应上游的 `OssUploadModel`。
public struct UploadImage: Sendable, Equatable {
    /// 登记用的文件名（随机名 + 类型后缀），服务端会另行分配存储路径。
    public let name: String
    public let data: Data
    public let width: Int
    public let height: Int
    /// 如 `image/jpeg`，同时用作直传时的 `Content-Type`。
    public let contentType: String

    public init(data: Data, width: Int, height: Int, contentType: String, name: String? = nil) {
        self.data = data
        self.width = width
        self.height = height
        self.contentType = contentType
        let suffix = contentType.split(separator: "/").last.map(String.init) ?? "png"
        self.name = name ?? "\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")).\(suffix)"
    }

    public var resolution: String { "\(width)x\(height)" }

    /// 文件内容的 MD5，小写十六进制。
    public var md5Hex: String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 按文件头判断图片类型；认不出时返回 `nil`。
    public static func sniffContentType(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if head.count >= 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }
}

/// 图片的用途，决定上传到哪个桶和目录，以及发布时引用图片的写法。
public enum UploadScope: Sendable, Equatable {
    /// 动态与回复的配图。
    case feed
    /// 发给某个用户的私信图片。
    case message(toUID: String)

    var bucket: String {
        switch self {
        case .feed: return "image"
        case .message: return "message"
        }
    }

    var directory: String {
        switch self {
        case .feed: return "feed"
        case .message: return "message"
        }
    }

    var toUID: String {
        switch self {
        case .feed: return ""
        case .message(let uid): return uid
        }
    }
}

/// `/v6/upload/ossUploadPrepare` 返回的临时凭证和各文件的存储路径。凭证不得写入日志。
struct OSSUploadTicket: Sendable, Equatable {
    var accessKeyID: String
    var accessKeySecret: String
    var securityToken: String
    /// 不带协议头的 OSS 接入点，如 `oss-cn-beijing.aliyuncs.com`。
    var endpoint: String
    var bucket: String
    var uploadImagePrefix: String
    /// 与请求里的图片一一对应的对象路径（`uploadFileName`）。
    var objectPaths: [String]

    /// 解析并校验准备接口的 `data`；字段不全时不继续上传。
    init(data: JSON, scope: UploadScope, count: Int) throws {
        let info = data["uploadPrepareInfo"]
        let incomplete = APIError(.invalidResponse, "图片上传配置不完整，请重试")
        guard data.object != nil, info.object != nil else {
            throw APIError(.invalidResponse, "无法准备图片上传，请重试")
        }
        guard let keyID = info["accessKeyId"].text, let secret = info["accessKeySecret"].text,
              let token = info["securityToken"].text, let rawEndpoint = info["endPoint"].text,
              let bucket = info["bucket"].text
        else { throw incomplete }
        var endpoint = rawEndpoint
        for scheme in ["https://", "http://"] where endpoint.hasPrefix(scheme) {
            endpoint.removeFirst(scheme.count)
        }
        let hostPattern = "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"
        guard endpoint.range(of: hostPattern, options: .regularExpression) != nil,
              bucket.range(of: hostPattern, options: .regularExpression) != nil
        else { throw incomplete }
        let paths = (data["fileInfo"].array ?? []).compactMap { $0["uploadFileName"].text }
        // 对象必须落在本次用途的目录下，且不含会改变签名资源的字符。
        guard paths.count == count, paths.allSatisfy({ path in
            path.hasPrefix(scope.directory + "/") && !path.contains("..") && !path.contains("?") && !path.contains("#")
        }) else { throw incomplete }
        accessKeyID = keyID
        accessKeySecret = secret
        securityToken = token
        self.endpoint = endpoint
        self.bucket = bucket
        uploadImagePrefix = info["uploadImagePrefix"].string ?? ""
        objectPaths = paths
    }

    /// 发布接口里引用第 `index` 张图片的写法：动态用完整地址，私信用以 `/` 开头的对象路径。
    func reference(at index: Int, scope: UploadScope) -> String {
        switch scope {
        case .feed: return "\(uploadImagePrefix)/\(objectPaths[index])"
        case .message: return "/\(objectPaths[index])"
        }
    }
}

/// 阿里云 OSS 直传的请求构造与签名（OSS V1 签名，STS 临时凭证）。移植自上游的 `AliyunOssClient`。
enum OSSUpload {
    /// 上传成功后由 OSS 回调酷安的固定参数，取值与上游一致。
    static let callback = "eyJjYWxsYmFja0JvZHlUeXBlIjoiYXBwbGljYXRpb25cL2pzb24iLCJjYWxsYmFja0hvc3QiOiJhcGkuY29vbGFway5jb20iLCJjYWxsYmFja1VybCI6Imh0dHBzOlwvXC9hcGkuY29vbGFway5jb21cL3Y2XC9jYWxsYmFja1wvbW9iaWxlT3NzVXBsb2FkU3VjY2Vzc0NhbGxiYWNrP2NoZWNrQXJ0aWNsZUNvdmVyUmVzb2x1dGlvbj0wJnZlcnNpb25Db2RlPTIxMDIwMzEiLCJjYWxsYmFja0JvZHkiOiJ7XCJidWNrZXRcIjoke2J1Y2tldH0sXCJvYmplY3RcIjoke29iamVjdH0sXCJoYXNQcm9jZXNzXCI6JHt4OnZhcjF9fSJ9"
    static let callbackVar = "eyJ4OnZhcjEiOiJmYWxzZSJ9"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// 请求头 `Date` 的取值，如 `Wed, 25 Nov 2026 08:00:00 GMT`。
    static func httpDate(_ date: Date) -> String { dateFormatter.string(from: date) }

    /// 文件内容 MD5 的 Base64，用作 `Content-MD5`。
    static func contentMD5(_ data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }

    /// 参与签名的字符串：方法、MD5、类型、日期、按名称排序的 `x-oss-` 请求头、资源路径，逐行拼接。
    static func canonicalString(
        method: String, contentMD5: String, contentType: String, date: String,
        headers: [String: String], bucket: String, objectPath: String
    ) -> String {
        let ossHeaders = headers
            .map { (key: $0.key.lowercased().trimmingCharacters(in: .whitespaces),
                    value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.key.hasPrefix("x-oss-") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n")
        let resource = bucket.isEmpty && objectPath.isEmpty ? "/" : "/\(bucket)/\(objectPath)"
        return [method, contentMD5, contentType, date, ossHeaders, resource].joined(separator: "\n")
    }

    /// `Authorization` 请求头：`OSS <AccessKeyId>:<Base64(HMAC-SHA1(密钥, 签名串))>`。
    static func authorization(accessKeyID: String, accessKeySecret: String, canonicalString: String) -> String {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(canonicalString.utf8), using: SymmetricKey(data: Data(accessKeySecret.utf8)))
        return "OSS \(accessKeyID):\(Data(mac).base64EncodedString())"
    }

    /// 组装把一张图片 PUT 到 OSS 的请求。
    static func request(
        ticket: OSSUploadTicket, objectPath: String, data: Data, contentType: String, date: Date = Date()
    ) throws -> URLRequest {
        let encodedPath = objectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectPath
        guard let url = URL(string: "https://\(ticket.bucket).\(ticket.endpoint)/\(encodedPath)") else {
            throw APIError(.invalidResponse, "图片上传配置不完整，请重试")
        }
        let headers: [String: String] = [
            "Content-Type": contentType,
            "Content-MD5": contentMD5(data),
            "Date": httpDate(date),
            "x-oss-security-token": ticket.securityToken,
            "x-oss-callback-var": callbackVar,
            "x-oss-callback": callback,
        ]
        let canonical = canonicalString(
            method: "PUT", contentMD5: headers["Content-MD5"]!, contentType: contentType, date: headers["Date"]!,
            headers: headers, bucket: ticket.bucket, objectPath: objectPath)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(
            authorization(accessKeyID: ticket.accessKeyID, accessKeySecret: ticket.accessKeySecret,
                          canonicalString: canonical),
            forHTTPHeaderField: "Authorization")
        request.httpBody = data
        return request
    }

    /// `uploadFileList` 字段：每张图片一个 `{"name","resolution","md5"}`，键的顺序和分隔与上游一致。
    static func uploadFileList(_ images: [UploadImage]) -> String {
        func quoted(_ text: String) -> String {
            var result = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
        let items = images.map {
            "{\"name\":\(quoted($0.name)),\"resolution\":\(quoted($0.resolution)),\"md5\":\(quoted($0.md5Hex))}"
        }
        return "[" + items.joined(separator: ", ") + "]"
    }

    /// 准备接口的表单字段。
    static func prepareFields(images: [UploadImage], scope: UploadScope) -> [(String, String)] {
        [
            ("uploadBucket", scope.bucket),
            ("uploadDir", scope.directory),
            ("is_anonymous", "0"),
            ("uploadFileList", uploadFileList(images)),
            ("toUid", scope.toUID),
        ]
    }
}

extension CoolapkClient {
    /// 上传进度：正在传第 `index` 张（从 0 起）共 `total` 张，`fraction` 为这一张已发送的比例。
    public struct UploadProgress: Sendable, Equatable {
        public let index: Int
        public let total: Int
        public let fraction: Double
    }

    /// 向酷安登记要上传的图片，换取 OSS 临时凭证。
    func prepareUpload(_ images: [UploadImage], scope: UploadScope) async throws -> OSSUploadTicket {
        let response = try await postMultipart(
            "/v6/upload/ossUploadPrepare", fields: OSSUpload.prepareFields(images: images, scope: scope))
        return try OSSUploadTicket(data: response.data, scope: scope, count: images.count)
    }

    /// 登记并逐张直传图片，返回可填进发布接口的图片引用（顺序与传入一致）。需要登录。
    public func uploadImages(
        _ images: [UploadImage], scope: UploadScope,
        progress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> [String] {
        guard !images.isEmpty else { return [] }
        guard images.allSatisfy({ !$0.data.isEmpty && $0.contentType.hasPrefix("image/") }) else {
            throw APIError(.business, "请选择有效的图片文件")
        }
        let ticket = try await prepareUpload(images, scope: scope)
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()
            let total = images.count
            progress?(UploadProgress(index: index, total: total, fraction: 0))
            let request = try OSSUpload.request(
                ticket: ticket, objectPath: ticket.objectPaths[index], data: image.data, contentType: image.contentType)
            let failure = APIError(
                .transport, total == 1 ? "图片上传失败，请检查网络后重试" : "第 \(index + 1) 张图片上传失败，请稍后重试")
            do {
                let (_, http) = try await sendExternal(request) { fraction in
                    progress?(UploadProgress(index: index, total: total, fraction: fraction))
                }
                guard (200..<300).contains(http.statusCode) else { throw failure }
            } catch let error as APIError where error.kind == .cancelled {
                throw error
            } catch {
                throw failure
            }
        }
        return images.indices.map { ticket.reference(at: $0, scope: scope) }
    }
}
