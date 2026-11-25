import CoolapkKit
import SwiftUI
import UniformTypeIdentifiers

/// 交给系统保存面板的导出文件。
struct FeedExportFile: FileDocument {
    static let readableContentTypes = FeedExportFormat.allCases.map(\.contentType)

    let prepared: PreparedFeedExport

    init(_ prepared: PreparedFeedExport) {
        self.prepared = prepared
    }

    /// 只用于写出，不支持从文件读回。
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: prepared.data)
    }
}

/// “保存内容”控件：选格式、准备数据、确认缺失项，再由系统保存面板写出文件。
/// 可直接放进工具栏；放在别处时由调用方加 `.buttonStyle(.glass)`。
struct FeedExportButton: View {
    let feed: Entity

    @Environment(AppModel.self) private var app
    @State private var task: Task<Void, Never>?
    @State private var isPreparing = false
    /// 有缺失项、等待用户确认的导出结果。
    @State private var pending: PreparedFeedExport?
    @State private var isConfirming = false
    @State private var file: FeedExportFile?
    @State private var isExporting = false

    var body: some View {
        Menu {
            Section("正文与最多三条评论；置顶优先，其余按热门排序") {
                ForEach(FeedExportFormat.allCases) { format in
                    Button {
                        start(format)
                    } label: {
                        Label(format.title, systemImage: format.systemImage)
                        Text(format.detail)
                    }
                }
            }
        } label: {
            Label(isPreparing ? "正在准备保存内容" : "保存内容",
                  systemImage: isPreparing ? "arrow.down.circle.dotted" : "square.and.arrow.down")
        }
        .disabled(isPreparing)
        .help(isPreparing ? "正在准备保存内容" : "保存内容")
        .alert("部分内容未能保存", isPresented: $isConfirming, presenting: pending) { prepared in
            Button("继续保存") {
                // 等确认框收起后再弹出保存面板，两者不能同时展示。
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    save(prepared)
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { prepared in
            Text(prepared.warnings.joined(separator: "\n\n") + "\n\n继续保存已取得的内容？")
        }
        .fileExporter(isPresented: $isExporting, document: file,
                      contentType: file?.prepared.format.contentType ?? .plainText,
                      defaultFilename: file?.prepared.fileName) { result in
            switch result {
            case .success: app.showToast("内容已保存")
            case .failure: app.showToast("保存失败，请检查目录权限和剩余空间后重试")
            }
            file = nil
        }
        .onDisappear { task?.cancel() }
    }

    private func start(_ format: FeedExportFormat) {
        guard !isPreparing else { return }
        // 先固定当前显示的内容，再去等网络。
        let feed = feed
        let service = FeedExportService(client: app.client, blockedUIDs: Set(app.library.blocked.map(\.uid)))
        isPreparing = true
        task = Task {
            defer { isPreparing = false }
            do {
                let prepared = try await service.prepare(feed, format: format)
                guard !Task.isCancelled else { return }
                if prepared.warnings.isEmpty {
                    save(prepared)
                } else {
                    pending = prepared
                    isConfirming = true
                }
            } catch is CancellationError {
                // 离开详情页会取消导出，无需提示。
            } catch {
                app.showToast("保存失败，请稍后重试")
            }
        }
    }

    private func save(_ prepared: PreparedFeedExport) {
        pending = nil
        file = FeedExportFile(prepared)
        isExporting = true
    }
}
