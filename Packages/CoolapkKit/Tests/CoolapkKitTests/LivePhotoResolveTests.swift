import XCTest
@testable import CoolapkKit

final class LivePhotoResolveTests: XCTestCase {
    /// 列表里的帖子只有 `picArr`：实况要能靠文件名标记识别，并带上帖子编号。
    func testListEntityMarksLivePhotoWithContentID() {
        let url = "http://image.coolapk.com/feed/2026/1124/22/9116353_8784a917_9862_8582_765-livepic@1280x1707.jpg"
        let entity = Entity(JSON.parse(#"{"entityType":"feed","id":75256541,"picArr":["\#(url)"],"pic":"\#(url)"}"#)!)
        let items = entity.mediaItems(for: entity.pictures)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isLivePhoto)
        XCTAssertEqual(items[0].contentID, "75256541")
        XCTAssertEqual(items[0].contentType, .feed)
    }

    func testFirstVideoURLReadsNestedResponse() {
        let body = JSON.parse(#"{"data":{"urlList":["https://image.coolapk.com/feed/a-livepic@1x1.jpg.mp4?t=1&sign=2"]}}"#)!
        XCTAssertEqual(CoolapkClient.firstVideoURL(in: body)?.pathExtension, "mp4")
        XCTAssertNil(CoolapkClient.firstVideoURL(in: JSON.parse(#"{"data":[]}"#)!))
    }
}
