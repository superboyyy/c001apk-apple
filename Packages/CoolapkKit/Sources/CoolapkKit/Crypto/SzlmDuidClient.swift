import CryptoKit
import Foundation
import zlib

/// 数盟设备标识请求错误；绝不包含报文、响应体、URL 或底层网络异常详情。
public struct SzlmDuidError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// `libdu` 字段编解码：移植自上游 `szlm_duid_client.dart`（参考 `szlm_res` `tools/unenc.py`，MIT；
/// P 派生、置换与校验和偏移署名 People-11）。输入仅为本机安装种子，绝不读取硬件标识。
public enum SzlmFieldCodec {
    public static func parameter(_ timestamp: String) -> Int {
        let tail = timestamp.suffix(3).replacingOccurrences(of: ".", with: "")
        return Int(tail) ?? 0
    }

    public static func encode(_ value: String, p: Int) -> String {
        let k = (p % 100) % 57 + 1
        let shifted = value.utf8.map { byte -> UInt8 in
            let offset = (Int(byte) - 32 + k) % 95
            return UInt8((offset < 0 ? offset + 95 : offset) + 32)
        }
        let n = shifted.count
        let m = n / 2
        var out: [UInt8] = []
        out.reserveCapacity(n)
        switch (p / 100) % 4 {
        case 0:
            if n % 2 == 1 { out.append(shifted[m]) }
            for i in 0..<m {
                out.append(shifted[n - 1 - i])
                out.append(shifted[m - 1 - i])
            }
        case 1:
            for i in 0..<m {
                out.append(shifted[n - 1 - i])
                out.append(shifted[i])
            }
            if n % 2 == 1 { out.append(shifted[m]) }
        case 2:
            var i = n - 1
            while i >= 0 {
                out.append(shifted[i])
                i -= 2
            }
            i = n - 2
            while i >= 0 {
                out.append(shifted[i])
                i -= 2
            }
        default:
            var i = 0
            while i < n {
                out.append(shifted[i])
                i += 2
            }
            i = 1
            while i < n {
                out.append(shifted[i])
                i += 2
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func anchor(_ value: String, p: Int) -> String {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return "" }
        let index = bytes.count > 9 ? bytes.count - 1 - (p % 10) : bytes.count - 1
        var trimmed = bytes
        trimmed.remove(at: index)
        return encode(String(decoding: trimmed, as: UTF8.self), p: p)
    }

    public static func checksum(_ value: String, p: Int) -> String {
        let sum = value.utf8.reduce(0) { $0 + Int($1) } + (p % 100) / 10
        let digest = Insecure.MD5.hash(data: Data(String(sum).utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(7))
    }
}

/// 数字联盟（`cn.shuzilm`）DUID 注册协议客户端。
/// 移植自上游 `TG-Twilight/c001apk` 的 `szlm_duid_client.dart`。
public enum SzlmDuidClient {
    public static let host = "auni.telecome.cn"
    public static let fallbackHost = "global-auni.checktrustworthiness.com"
    public static let reportPath = "/a/mdna/report?v=8.7&t=m&p=F9BD0FBDACFE80FCF34370FBCFEE1A98"
    public static let timeout: TimeInterval = 15
    public static let maxResponseBytes = 64 * 1024

    public typealias Sender = @Sendable (URL, Data) async throws -> Data

    private static let poolKey = Array(#"xp7j@&!v5]2k#+3z{n9$q^r%[8f1*d4e:c>0l?m/6)yb-=w}"#.utf8)
    private static let hexDigits = Array("0123456789abcdef")
    private static let seedRegex = try! NSRegularExpression(pattern: #"^[0-9a-f]{32}$"#)
    private static let canonicalFieldOrder = [
        "DUv", "75c", "3mS", "AAA", "BBB", "2cO", "foO", "sfOo",
        "P1J", "AYk", "dLH", "R37", "R3d", "R41", "SAN",
    ]

    public static func isValidSeed(_ seed: String) -> Bool {
        let range = NSRange(seed.startIndex..<seed.endIndex, in: seed)
        return seedRegex.firstMatch(in: seed, range: range) != nil
    }

    public static func createSeed() -> String {
        var generator = SystemRandomNumberGenerator()
        return createSeed(using: &generator)
    }

    public static func createSeed<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String((0..<32).map { _ in hexDigits[Int.random(in: 0..<16, using: &generator)] })
    }

    /// 构造仅包含协议锚点与非唯一机型参数的报文；种子本身绝不会直接写入 `X-App-Device`。
    public static func buildReport(
        seed: String,
        ts: String,
        manufacturer: String = "Google",
        model: String = "Pixel 7",
        androidVersion: String = "13",
        sdkInt: Int = 33
    ) throws -> [String: JSON] {
        guard isValidSeed(seed) else {
            throw SzlmDuidError("本机设备报文配置无法读取")
        }
        let input = String(seed.prefix(16))
        let p = SzlmFieldCodec.parameter(ts)
        let sha1Hex = Array(
            Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02X", $0) }.joined()
        )
        let mac = "\(String(sha1Hex[1..<7])):\(String(sha1Hex[13..<19])):\(String(sha1Hex[7..<13]))"
        return [
            "DUv": .string("com.coolapk.market"),
            "75c": .string("11e7b222083a4b732b4b14811f6fc05995a01415eb"),
            "3mS": .string("v9.0.1"),
            "AAA": .string("v1.0"),
            "BBB": .string("v1.0"),
            "2cO": .string(ts),
            "foO": .string(SzlmFieldCodec.anchor(input, p: p)),
            "sfOo": .string(SzlmFieldCodec.checksum(input, p: p)),
            "P1J": .string(mac),
            "AYk": .string(mac),
            "dLH": .string(SzlmFieldCodec.encode(seed, p: p)),
            "R37": .string(manufacturer),
            "R3d": .string(model),
            "R41": .string(androidVersion),
            "SAN": .number(Double(sdkInt)),
        ]
    }

    /// 紧凑 JSON（转义 `/` 为 `\/`）→ RFC 1950 zlib（level 6）压缩 → 48 字节常量池 XOR。
    public static func encodeReport(_ report: [String: JSON]) throws -> Data {
        let jsonText = serializeCompactJSON(report)
        let compressed = try zlibCompress(Data(jsonText.utf8), level: 6)
        return xor(compressed)
    }

    /// 解密服务端响应（兼容 zlib 压缩与未压缩 JSON），严格拒绝全 0 及非字符串应答。
    public static func decodeID(_ raw: Data) -> String? {
        guard !raw.isEmpty, raw.count <= maxResponseBytes else { return nil }
        let plain = xor(raw)
        let payload: Data
        if plain.count >= 2, plain[0] == 0x78, ((Int(plain[0]) << 8) + Int(plain[1])) % 31 == 0 {
            guard let inflated = try? zlibDecompress(plain, maxBytes: maxResponseBytes) else { return nil }
            payload = inflated
        } else {
            payload = plain
        }
        guard let body = JSON.parse(payload), case .object(let map) = body else { return nil }
        guard isZeroError(map["err"]) else { return nil }
        if let primary = map["n_a"], primary != .null {
            if case .string(let text) = primary {
                if !text.isEmpty {
                    // 明确返回的非空字段（含全 0 拒绝）绝不回退到 cdd。
                    return OfficialDeviceIdentity.validate(text)
                }
            } else {
                return nil
            }
        }
        if case .string(let fallback) = map["cdd"] {
            return OfficialDeviceIdentity.validate(fallback)
        }
        return nil
    }

    /// 构造一份报文，仅在传输失败时顺序尝试备用域名；绝不并发双发，也不对服务端明确拒绝重试。
    public static func fetch(
        seed: String,
        manufacturer: String = "Google",
        model: String = "Pixel 7",
        androidVersion: String = "13",
        sdkInt: Int = 33,
        post: Sender? = nil,
        randomNumber: (@Sendable (Int) -> Int)? = nil,
        now: Date? = nil
    ) async throws -> String {
        let nextInt: (Int) -> Int = { upper in
            if let randomNumber { return abs(randomNumber(upper)) % upper }
            return Int.random(in: 0..<upper)
        }
        let time = now ?? Date()
        let interval = time.timeIntervalSince1970
        let seconds = Int64(floor(interval))
        let micros = max(0, min(999_999, Int(floor((interval - Double(seconds)) * 1_000_000))))
        let nanos = micros * 1000 + nextInt(999) + 1
        let ts = "\(seconds).\(nanos)"

        let report = try buildReport(
            seed: seed,
            ts: ts,
            manufacturer: manufacturer,
            model: model,
            androidVersion: androidVersion,
            sdkInt: sdkInt
        )
        let body = try encodeReport(report)
        let requestID = String((0..<32).map { _ in hexDigits[nextInt(16)] })
        let path = "\(reportPath)&r=\(requestID)&n=0&l=2&h=0"
        let sender: Sender = post ?? { url, payload in try await defaultPost(url: url, body: payload) }

        for target in [host, fallbackHost] {
            guard let url = URL(string: "https://\(target)\(path)") else {
                throw SzlmDuidError("无法连接设备标识服务，请稍后重试")
            }
            let raw: Data
            do {
                raw = try await sender(url, body)
            } catch {
                if target == host { continue }
                throw SzlmDuidError("无法连接设备标识服务，请检查网络后稍后重试")
            }
            guard let id = decodeID(raw) else {
                throw SzlmDuidError("取号失败：服务端没有返回有效的设备标识")
            }
            return id
        }
        throw SzlmDuidError("无法连接设备标识服务，请稍后重试")
    }

    // MARK: - 网络与编解码内部辅助

    private static func isZeroError(_ value: JSON?) -> Bool {
        guard let value else { return false }
        switch value {
        case .string(let text): return text == "0"
        case .number(let number): return number == 0
        default: return false
        }
    }

    private static func defaultPost(url: URL, body: Data) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = body

        let (asyncBytes, response) = try await session.bytes(for: request, delegate: SzlmRedirectBlocker())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SzlmDuidError("设备标识服务暂时不可用")
        }
        var data = Data()
        for try await byte in asyncBytes {
            if data.count >= maxResponseBytes {
                throw SzlmDuidError("设备标识服务响应异常")
            }
            data.append(byte)
        }
        return data
    }

    static func xor(_ data: Data) -> Data {
        var result = Data(count: data.count)
        let keyCount = poolKey.count
        result.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                guard let outPtr = outBuf.bindMemory(to: UInt8.self).baseAddress,
                      let inPtr = inBuf.bindMemory(to: UInt8.self).baseAddress
                else { return }
                for i in 0..<data.count {
                    outPtr[i] = inPtr[i] ^ poolKey[i % keyCount]
                }
            }
        }
        return result
    }

    static func zlibCompress(_ input: Data, level: Int32 = 6) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw SzlmDuidError("设备报文编码失败")
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 4096
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        let status: Int32 = input.withUnsafeBytes { rawInput in
            stream.next_in = UnsafeMutablePointer(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result: Int32 = Z_OK
            repeat {
                let produced: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                    stream.next_out = rawBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    result = deflate(&stream, Z_FINISH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
            } while result == Z_OK
            return result
        }
        guard status == Z_STREAM_END else {
            throw SzlmDuidError("设备报文编码失败")
        }
        return output
    }

    static func zlibDecompress(_ input: Data, maxBytes: Int) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw SzlmDuidError("设备响应解码失败")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 4096
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        var exceeded = false
        let status: Int32 = input.withUnsafeBytes { rawInput in
            stream.next_in = UnsafeMutablePointer(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result: Int32 = Z_OK
            repeat {
                let produced: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                    stream.next_out = rawBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    result = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if output.count + produced > maxBytes {
                    exceeded = true
                    return Z_BUF_ERROR
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
            } while result == Z_OK
            return result
        }
        guard !exceeded, status == Z_STREAM_END else {
            throw SzlmDuidError("设备响应解码失败")
        }
        return output
    }

    private static func serializeCompactJSON(_ map: [String: JSON]) -> String {
        let canonicalSet = Set(canonicalFieldOrder)
        let extraKeys = map.keys.filter { !canonicalSet.contains($0) }.sorted()
        let orderedKeys = canonicalFieldOrder.filter { map[$0] != nil } + extraKeys
        let entries = orderedKeys.compactMap { key -> String? in
            guard let value = map[key] else { return nil }
            return "\"\(escapeJSONString(key))\":\(serializeJSONValue(value))"
        }
        return "{\(entries.joined(separator: ","))}"
    }

    private static func serializeJSONValue(_ value: JSON) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            if number.isFinite, number == number.rounded(), abs(number) < 1e15 {
                return String(Int64(number))
            }
            return String(number)
        case .string(let text):
            return "\"\(escapeJSONString(text))\""
        case .array(let items):
            return "[\(items.map(serializeJSONValue).joined(separator: ","))]"
        case .object(let dict):
            return serializeCompactJSON(dict)
        }
    }

    private static func escapeJSONString(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += #"\""#
            case 0x5C: out += #"\\"#
            case 0x2F: out += #"\/"#
            case 0x08: out += #"\b"#
            case 0x0C: out += #"\f"#
            case 0x0A: out += #"\n"#
            case 0x0D: out += #"\r"#
            case 0x09: out += #"\t"#
            case 0x00..<0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// 拒绝跟随重定向，避免设备报文被转往未知主机。
private final class SzlmRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
