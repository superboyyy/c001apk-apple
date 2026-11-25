import Foundation

/// 私信：会话列表、聊天记录、发送与会话管理（需要登录）。对照上游 `NetworkRepo` 的私信部分。
extension CoolapkClient {
    /// 两个用户之间会话的标识：两个 uid 按数值从小到大用下划线连接。
    public static func chatKey(uid: String, with other: String) -> String? {
        guard let first = Int(uid), let second = Int(other), first > 0, second > 0 else { return nil }
        return "\(min(first, second))_\(max(first, second))"
    }

    /// 私信会话列表，每行是与一个用户的最近一条消息。
    public func messageList(page: Int, firstItem: String? = nil, lastItem: String? = nil) async throws -> EntityPage {
        let response = try await get("/v6/message/list", query: messageCursor(page, firstItem, lastItem))
        return CoolapkClient.page(from: response)
    }

    /// 一个会话的聊天记录。每页内按时间从旧到新排列，页码越大越早；
    /// 结果里除 `message` 外还有 `messageExtra`（时间分隔）等行。
    public func chatHistory(
        ukey: String, page: Int, firstItem: String? = nil, lastItem: String? = nil
    ) async throws -> EntityPage {
        let response = try await get(
            "/v6/message/chat", query: [("ukey", ukey)] + messageCursor(page, firstItem, lastItem))
        var result = CoolapkClient.page(from: response, keepAll: true)
        result.items.removeAll { entity in
            !["message", "messageExtra"].contains(entity.entityType)
                && !CoolapkClient.acceptedEntityTypes.contains(entity.entityType)
                && entity.entityTemplate != "noMoreDataCard"
        }
        return result
    }

    private func messageCursor(_ page: Int, _ firstItem: String?, _ lastItem: String?) -> [(String, String?)] {
        var items: [(String, String?)] = [("page", String(page))]
        if let firstItem, !firstItem.isEmpty { items.append(("firstItem", firstItem)) }
        if let lastItem, !lastItem.isEmpty { items.append(("lastItem", lastItem)) }
        return items
    }

    /// 发送一条私信。`pic` 是 `uploadImages(_:scope: .message(toUID:))` 返回的图片引用，纯文字时留空。
    /// 服务端没有返回消息记录时抛出 `invalidResponse`：此时发送结果未知，不要自动重发。
    public func sendMessage(uid: String, message: String, pic: String = "") async throws -> Entity {
        let response = try await postMultipart(
            "/v6/message/send", query: [("uid", uid)], fields: [("message", message), ("message_pic", pic)])
        let rows = response.data.array ?? (response.data.object == nil ? [] : [response.data])
        guard let sent = rows.first(where: { $0["entityType"].string == "message" && $0["id"].text != nil }) else {
            throw APIError(.invalidResponse, "服务端未返回消息记录，发送结果未确认")
        }
        return Entity(sent)
    }

    /// 私信图片的真实地址：接口以 302 跳转给出，这里只取跳转目标。
    public func messageImageURL(id: String) async throws -> URL? {
        try await redirectLocation("/v6/message/showImage", query: [("id", id), ("type", "s")])
    }

    /// 置顶或取消置顶一个会话。
    public func setConversationPinned(_ pinned: Bool, ukey: String) async throws {
        try await mutateMessage(pinned ? "/v6/message/addTop" : "/v6/message/removeTop", query: [("ukey", ukey)])
    }

    /// 从会话列表删除一个会话。
    public func deleteConversation(ukey: String) async throws {
        try await mutateMessage("/v6/message/deleteChat", query: [("ukey", ukey)])
    }

    /// 删除会话里的一条消息。
    public func deleteMessage(ukey: String, id: String) async throws {
        try await mutateMessage("/v6/message/delete", query: [("ukey", ukey), ("id", id)])
    }

    /// 这些操作成功时 `data`（或 `data.count`）非空；否则视为服务端没有确认。
    private func mutateMessage(_ path: String, query: [(String, String?)]) async throws {
        let response = try await get(path, query: query)
        guard CoolapkClient.confirmsMessageMutation(response.data) else {
            throw APIError(.invalidResponse, "服务端未确认操作结果，请刷新后查看")
        }
    }

    static func confirmsMessageMutation(_ data: JSON) -> Bool {
        let count = data.object == nil ? data : data["count"]
        switch count {
        case .null, .bool(false): return false
        case .string(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }
}
