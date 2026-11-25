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
