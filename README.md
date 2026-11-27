# c001apk-apple

**酷果**：酷安的非官方原生客户端，支持 **macOS** 与 **iPadOS**。用 SwiftUI 编写（macOS 部分配合 AppKit），界面采用 Liquid Glass。

协议实现移植自 [c001apk](https://github.com/TG-Twilight/c001apk)。本项目与酷安官方无关。

![酷果 macOS 主界面](docs/screenshots/macos-home.jpg)

## 功能

- 头条、热榜、酷图、话题、数码，瀑布流信息流
- 帖子与图文详情，宽屏下左正文右评论
- 搜索、用户主页、话题与产品页、应用页
- 登录后：点赞、关注、评论、发帖、私信、通知，支持多账号
- 本机功能：收藏、浏览历史、屏蔽、内容过滤、悄悄关注、帖子导出
- 图片查看器，支持 HDR 与实况图片

游客可以直接浏览；查看完整评论需要在应用内手动完成人机验证或登录。

## 构建

需要 macOS 26、Xcode 26 或更新版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate
```

```bash
open c001apk.xcodeproj
```

选择 `c001apk-macOS` 或 `c001apk-iPadOS` 运行。在真机 iPad 上运行可在仓库根目录新建 `Local.xcconfig`（已被 `.gitignore` 忽略，参考 `Signing.xcconfig`）填入自己的开发团队与自动签名配置，重新运行 `xcodegen generate` 也不会被覆盖。

协议层可以单独测试：

```bash
cd Packages/CoolapkKit && swift test
```

## 目录

```text
Packages/CoolapkKit   协议层：签名、网络、数据模型（无界面）
App/Shared            两个平台共用的界面与逻辑
App/macOS             macOS 专用代码（AppKit）
App/iPadOS            iPadOS 专用代码（UIKit）
App/Resources         图标、颜色、表情
```

## 许可

[GNU AGPL v3](LICENSE)。第三方来源见 [NOTICE.md](NOTICE.md)。
