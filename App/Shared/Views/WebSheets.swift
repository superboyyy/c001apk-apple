import CoolapkKit
import SwiftUI
import WebKit

// MARK: - 人机验证

/// 用 `WKWebView` 承载验证组件。用户手动完成验证；得到的凭据直接交还给
/// 等待中的请求，绝不存入导航状态、日志或外部浏览器。
struct CaptchaSheet: View {
    let request: CaptchaRequest
    @State private var reloadToken = 0
    @State private var showingHelp = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("人机验证", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                Button {
                    showingHelp = true
                } label: {
                    Label("重复验证帮助", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .help("反复出现人机验证？")
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("反复出现人机验证？").font(.headline)
                        Text("可在“设置 → 账号与设备 → 数盟设备标识”里获取数盟 ID，或从 Android 官方酷安同一页面点击“复制 OAID”5 次后粘贴完整内容手动导入。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("仓库图文说明", destination: OfficialDeviceIdentity.guideURL)
                            .font(.callout)
                    }
                    .padding(14)
                    .frame(width: 280)
                }
                Button {
                    reloadToken += 1
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                Button("取消", role: .cancel) { request.finish(nil) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            WebViewContainer(host: CaptchaWebView(request: request))
                .id(reloadToken)
            Divider()
            Text("酷安要求完成验证后才能继续读取内容。验证由网易易盾提供，验证结果仅用于本次会话。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 420, height: 480)
    }
}

/// 跨平台的 WKWebView 容器：子类型只需实现 `makeWebView`。
protocol WebViewHosting {
    associatedtype Coordinator
    func makeCoordinator() -> Coordinator
    @MainActor func makeWebView(coordinator: Coordinator) -> WKWebView
    @MainActor func updateWebView(_ webView: WKWebView, coordinator: Coordinator)
}

extension WebViewHosting {
    func updateWebView(_ webView: WKWebView, coordinator: Coordinator) {}
}

#if os(macOS)
/// 把 `WebViewHosting` 桥接成 SwiftUI 视图。
struct WebViewContainer<Host: WebViewHosting>: NSViewRepresentable {
    let host: Host
    func makeCoordinator() -> Host.Coordinator { host.makeCoordinator() }
    func makeNSView(context: Context) -> WKWebView { host.makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) { host.updateWebView(nsView, coordinator: context.coordinator) }
}
#else
struct WebViewContainer<Host: WebViewHosting>: UIViewRepresentable {
    let host: Host
    func makeCoordinator() -> Host.Coordinator { host.makeCoordinator() }
    func makeUIView(context: Context) -> WKWebView { host.makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) { host.updateWebView(uiView, coordinator: context.coordinator) }
}
#endif

private struct CaptchaWebView: WebViewHosting {
    let request: CaptchaRequest

    private static let baseURL = URL(string: "https://captcha.c001apk.invalid/")!

    func makeCoordinator() -> Coordinator { Coordinator(request: request) }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "captcha")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = request.userAgent
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        webView.loadHTMLString(Self.html(captchaID: request.challenge.captchaID), baseURL: Self.baseURL)
        return webView
    }

    /// 与 Flutter 端 `captcha_page.dart` 相同的页面，加上 WebKit 桥接。
    private static func html(captchaID: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>:root{color-scheme:light dark}body{font:14px -apple-system,sans-serif;margin:24px;color:CanvasText;background:transparent}#captcha{margin-top:20px}p{line-height:1.6}</style>
        </head><body><p id="status">正在加载验证组件…</p><div id="captcha"></div>
        <script>
        function statusText(text){document.getElementById('status').textContent=text;}
        function startCaptcha(){
          var timeout=setTimeout(function(){statusText('验证组件加载超时，请点击“重新加载”');},15000);
          var script=document.createElement('script');
          script.src='https://cstaticdun.126.net/load.min.js';
          script.onerror=function(){clearTimeout(timeout);statusText('验证组件加载失败，请检查网络后重新加载');};
          script.onload=function(){
            if(typeof initNECaptcha!=='function'){clearTimeout(timeout);statusText('验证组件不可用，请重新加载');return;}
            try { initNECaptcha({captchaId:'\(captchaID)',element:'#captcha',protocol:'https',
              mode:'embed',apiVersion:2,width:Math.min(320,window.innerWidth-48)+'px',lang:'zh-CN',
              onVerify:function(err,data){
                if(!err && data && data.validate){window.webkit.messageHandlers.captcha.postMessage(data.validate);}
                else{statusText('验证未通过，请按提示重试');}
              }
            },function(){clearTimeout(timeout);statusText('请按下方提示完成人机验证');},
              function(){clearTimeout(timeout);statusText('无法初始化验证，请检查网络后重新加载');});
            } catch(e){clearTimeout(timeout);statusText('验证组件初始化失败，请重新加载');}
          };
          document.head.appendChild(script);
        }
        window.addEventListener('DOMContentLoaded',startCaptcha);
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let request: CaptchaRequest
        private var finished = false

        init(request: CaptchaRequest) { self.request = request }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, message.name == "captcha", let validate = message.body as? String,
                  let proof = request.challenge.proof(validate: validate)
            else { return }
            finished = true
            request.finish(proof)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // 页面不会跳转；让顶层 frame 始终停在本地文档上。
            let isInitial = navigationAction.request.url?.host == CaptchaWebView.baseURL.host
                || navigationAction.request.url?.scheme == "about"
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            decisionHandler(isMainFrame && !isInitial ? .cancel : .allow)
        }
    }
}

// MARK: - 登录

/// 在酷安官方账号页面登录。账号密码只输入到官网，
/// 应用只读取登录后得到的账号 Cookie。
struct LoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var isFinishing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("登录酷安", systemImage: "person.crop.circle")
                    .font(.headline)
                if isLoading || isFinishing { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            WebViewContainer(host: LoginWebView(userAgent: app.identity.userAgent, isLoading: $isLoading) { account in
                guard !isFinishing else { return }
                isFinishing = true
                Task {
                    await app.signIn(account)
                    dismiss()
                }
            })
            Divider()
            Text("此页面由酷安官方账号站点提供，账号与密码只会提交给酷安。登录成功后，本应用仅保存登录凭证到系统钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(width: 460, height: 680)
    }
}

private struct LoginWebView: WebViewHosting {
    let userAgent: String
    @Binding var isLoading: Bool
    let onLogin: (Account) -> Void

    static let loginURL = URL(string: "https://account.coolapk.com/auth/login?type=mobile")!

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 使用独立的临时数据存储，登录过程不会影响其他网页视图。
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        var request = URLRequest(url: Self.loginURL)
        request.setValue("com.coolapk.market", forHTTPHeaderField: "X-Requested-With")
        webView.load(request)
        return webView
    }

    func updateWebView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LoginWebView
        private var completed = false

        init(parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            // 只有跳到官方落地页才算登录完成。
            guard !completed, let url = webView.url, url.scheme == "https", url.host == "www.coolapk.com",
                  url.path.isEmpty || url.path == "/"
            else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.completed else { return }
                var values: [String: String] = [:]
                for cookie in cookies where cookie.domain.hasSuffix("coolapk.com") {
                    values[cookie.name] = cookie.value
                }
                guard let uid = values["uid"], let username = values["username"], let token = values["token"],
                      !uid.isEmpty, !username.isEmpty, !token.isEmpty
                else { return }
                self.completed = true
                self.parent.onLogin(Account(uid: uid, username: username, token: token))
            }
        }
    }
}
