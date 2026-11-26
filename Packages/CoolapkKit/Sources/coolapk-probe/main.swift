import CoolapkKit
import Foundation

// 开发工具：以游客身份请求一个接口路径，并打印 JSON 响应。
//   swift run coolapk-probe /v6/feed/detail id=123 [--api2] [--raw]
// 设置 COOLAPK_DEVICE 可在多次运行间复用同一个设备码。

var arguments = Array(CommandLine.arguments.dropFirst())
let useAPI2 = arguments.contains("--api2")
let summary = arguments.contains("--summary")
let useWeb = arguments.contains("--web")
arguments.removeAll { $0.hasPrefix("--") }
// 调试实况：coolapk-probe --live <图片地址> <内容编号> [feed|reply|article]
if CommandLine.arguments.contains("--live"), arguments.count >= 2 {
    var media = FeedMedia(url: arguments[0], contentID: arguments[1],
                          contentType: MediaContentType(rawValue: arguments.count > 2 ? arguments[2] : "feed") ?? .feed)
    media.isLivePhoto = true
    let client = CoolapkClient(identity: ClientIdentity(deviceCode: ProcessInfo.processInfo.environment["COOLAPK_DEVICE"] ?? ""))
    do {
        print(try await client.livePhotoVideoURL(for: media)?.absoluteString ?? "nil")
    } catch {
        print("error:", error)
    }
    exit(0)
}

guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: coolapk-probe <path> [key=value …] [--api2] [--summary]\n".utf8))
    exit(2)
}
let query: [(String, String?)] = arguments.dropFirst().map { item in
    let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
}

var identity = ClientIdentity(deviceCode: ProcessInfo.processInfo.environment["COOLAPK_DEVICE"] ?? "")
let client = CoolapkClient(identity: identity)

// 调试会话：coolapk-probe <路径> [key=value …] --session [--alternate]
// 同一请求连发几次（--alternate 时在两个接口域名间轮换），看服务端何时换发会话 Cookie。
// 只打印指纹，不打印 Cookie 的值。
if CommandLine.arguments.contains("--session") {
    client.onSessionCookieChange = { cookie in
        let mark = cookie.map { $0.value.isEmpty ? "占位" : String(format: "%04x", abs($0.value.hashValue) % 65_536) }
        print("  会话 Cookie →", mark ?? "清除")
    }
    let alternate = CommandLine.arguments.contains("--alternate")
    for round in 1...4 {
        let api2 = alternate ? round % 2 == 0 : useAPI2
        do {
            _ = try await client.get(path, query: query, host: api2 ? CoolapkClient.api2Host : CoolapkClient.apiHost)
            print("第 \(round) 次（\(api2 ? "api2" : "api")）：成功")
        } catch {
            let failure = APIError.from(error)
            print("第 \(round) 次（\(api2 ? "api2" : "api")）：\(failure.kind) \(failure.serverStatus ?? "")")
        }
    }
    exit(0)
}

func describe(_ json: JSON, indent: String = "", depth: Int = 0) {
    guard depth < 3 else { return }
    switch json {
    case .object(let object):
        for key in object.keys.sorted() {
            let value = object[key]!
            switch value {
            case .object: print("\(indent)\(key): {…}"); describe(value, indent: indent + "  ", depth: depth + 1)
            case .array(let items): print("\(indent)\(key): [\(items.count)]"); if let first = items.first { describe(first, indent: indent + "  ", depth: depth + 1) }
            default:
                let text = value.string ?? "null"
                print("\(indent)\(key): \(text.prefix(90).replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
    default: break
    }
}

do {
    let response = try await client.get(path, query: query, host: useWeb ? CoolapkClient.webHost : (useAPI2 ? CoolapkClient.api2Host : CoolapkClient.apiHost))
    if summary {
        if let items = response.data.array {
            print("count:", items.count)
            for item in items {
                print("- \(item["entityType"].string ?? "?") / \(item["entityTemplate"].string ?? "-") id=\(item["id"].string ?? "-") title=\((item["title"].string ?? "").prefix(30)) entities=\(item["entities"].array?.count ?? 0) url=\((item["url"].string ?? "").prefix(60))")
            }
        } else {
            describe(response.data)
        }
    } else if let data = response.body.serialized(pretty: true) {
        print(String(decoding: data, as: UTF8.self))
    }
} catch let error as APIError {
    print("APIError(\(error.kind)): \(error.message)")
    exit(1)
}
