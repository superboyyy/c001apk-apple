import XCTest
@testable import CoolapkKit

/// 对应上游 `basic_media_contract_test.dart`，并补充真实接口里观察到的文件名标记。
final class FeedMediaTests: XCTestCase {
    private func entity(_ text: String) -> Entity { Entity(JSON.parse(text)!) }

    func testOrdinaryImagesKeepOrderAndOwner() {
        let items = FeedMedia.items(urls: ["https://example.com/a.jpg", "https://example.com/b.jpg"], contentID: "12")
        XCTAssertEqual(items.map(\.sourceURL), ["https://example.com/a.jpg", "https://example.com/b.jpg"])
        XCTAssertTrue(items.allSatisfy { $0.contentID == "12" && !$0.isLivePhoto && !$0.isHDR && $0.videoURL == nil })
    }

    func testLooseFileNameHintsAreNotTrusted() {
        let item = FeedMedia(url: "https://image.coolapk.com/example_hdr_live.jpg")
        XCTAssertFalse(item.isLivePhoto)
        XCTAssertFalse(item.isHDR)
        // 旧式文件名里的连字符片段不是素材标记。
        let legacy = FeedMedia(url: "http://image.coolapk.com/image/2026/1125/11/E696B0-E4BB8A-1125-0-o_1k88-uid-97100@1080x360.jpg")
        XCTAssertFalse(legacy.isLivePhoto || legacy.isHDR)
    }

    /// 样例取自 2026-11 游客搜索接口返回的 `picArr`。
    func testCoolapkFileNameMarks() {
        let feed = entity(#"""
        {"entityType": "feed", "id": 75269901, "picArr": [
          "http://image.coolapk.com/feed/2026/1125/17/3300584_578411a4_9100_7239_78-uhdr@3075x2696.jpg",
          "http://image.coolapk.com/feed/2026/1125/17/3300584_ee728927_9100_7249_622-livepic-uhdr@2499x3318.jpg",
          "http://image.coolapk.com/feed/2026/1125/17/3300584_2cd84c09_9100_7261_574-livepic@3840x2160.jpg",
          "http://image.coolapk.com/feed/2026/1119/21/1385852_bec22e29_3637_9765_448-xhdr@2494x3326.jpg",
          "http://image.coolapk.com/feed/2026/1125/13/23341323_dec9b176_4694_0071_132@1216x2640.jpg"
        ]}
        """#)
        let items = feed.mediaItems
        XCTAssertEqual(items.map(\.isHDR), [true, true, false, true, false])
        XCTAssertEqual(items.map(\.isLivePhoto), [false, true, true, false, false])
        XCTAssertTrue(items.allSatisfy { $0.contentID == "75269901" && $0.contentType == .feed && $0.videoURL == nil })
        XCTAssertEqual(items[0].sourceURL, feed.pictures[0])
        XCTAssertEqual(items[0].originalURL,
                       "https://image.coolapk.com/feed/2026/1125/17/3300584_578411a4_9100_7239_78-uhdr@3075x2696.jpg")
        // 缩略图后缀不影响标记。
        XCTAssertTrue(FeedMedia(url: items[1].sourceURL + ".m.jpg").isLivePhoto)
    }

    func testDisplayURLOnlyUpgradesCoolapkImageHost() {
        XCTAssertEqual(FeedMedia(url: "http://image.coolapk.com/a@1x2.jpg").displayURL, "https://image.coolapk.com/a@1x2.jpg")
        XCTAssertEqual(FeedMedia(url: "//image.coolapk.com/a@1x2.jpg").displayURL, "https://image.coolapk.com/a@1x2.jpg")
        XCTAssertEqual(FeedMedia(url: "http://example.com/a.jpg").displayURL, "http://example.com/a.jpg")
        let media = FeedMedia(sourceURL: "https://example.com/a.jpg", previewURL: "https://example.com/a.s.jpg")
        XCTAssertEqual(media.thumbnailURL, "https://example.com/a.s.jpg")
        XCTAssertEqual(FeedMedia(url: "https://example.com/a.jpg").thumbnailURL, "https://example.com/a.jpg")
    }

    func testMetadataObjectsSupplyVideoAndFlags() {
        let feed = entity(#"""
        {"entityType": "feed_reply", "id": "9",
         "picArr": ["https://image.coolapk.com/a@1x2.jpg", "https://image.coolapk.com/b@1x2.jpg"],
         "imageUriList": [
           {"url": "https://image.coolapk.com/b@1x2.jpg", "videoUrl": "https://video.example/b.mp4", "isHdr": 1,
            "previewUrl": "https://image.coolapk.com/b@1x2.jpg.s.jpg"},
           {"url": "https://image.coolapk.com/other.jpg", "isLivePhoto": true}
         ]}
        """#)
        let items = feed.mediaItems
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], FeedMedia(sourceURL: "https://image.coolapk.com/a@1x2.jpg", contentID: "9", contentType: .reply))
        XCTAssertEqual(items[1].videoURL, "https://video.example/b.mp4")
        XCTAssertTrue(items[1].isLivePhoto)
        XCTAssertTrue(items[1].isHDR)
        XCTAssertEqual(items[1].thumbnailURL, "https://image.coolapk.com/b@1x2.jpg.s.jpg")

        // 仅带 pic 字段的评论也能生成对应回复素材（包含文件名实况标记）。
        let picOnlyReply = entity(#"{"entityType": "feed_reply", "id": "10", "pic": "http://image.coolapk.com/r-livepic@1x1.jpg"}"#)
        XCTAssertEqual(picOnlyReply.mediaItems.count, 1)
        XCTAssertEqual(picOnlyReply.mediaItems[0].contentType, .reply)
        XCTAssertTrue(picOnlyReply.mediaItems[0].isLivePhoto)
    }

    func testMetadataAloneProvidesTheList() {
        let nested = entity(#"{"id": 3, "image_uri_list": "[{\"uri\": \"https://example.com/a-livepic@1x1.jpg\"}, \"https://example.com/b.jpg\"]"}"#)
        // `pictures` 已经从元数据里取出地址，顺序以它为准。
        XCTAssertEqual(nested.mediaItems.map(\.sourceURL), ["https://example.com/a-livepic@1x1.jpg", "https://example.com/b.jpg"])
        XCTAssertEqual(nested.mediaItems.map(\.isLivePhoto), [true, false])
        let direct = FeedMedia.items(metadata: JSON.parse(#"[{"pic": "https://example.com/c.jpg", "live_photo": "1"}]"#)!)
        XCTAssertEqual(direct.map(\.sourceURL), ["https://example.com/c.jpg"])
        XCTAssertTrue(direct[0].isLivePhoto)
        XCTAssertTrue(Entity(JSON.parse(#"{"id": 1}"#)!).mediaItems.isEmpty)
        // 字段名未知时，指向视频文件的地址也会被认出来。
        let unnamed = FeedMedia.items(metadata: JSON.parse(#"[{"url": "https://example.com/d.jpg", "extra": "https://example.com/d.MP4?sign=1", "w": 3}]"#)!)
        XCTAssertEqual(unnamed.first?.videoURL, "https://example.com/d.MP4?sign=1")
        XCTAssertEqual(unnamed.first?.isLivePhoto, true)
    }

    func testGalleryMapsBodyImagesWithoutBorrowingOwners() {
        let known = [FeedMedia(sourceURL: "http://image.coolapk.com/a-livepic@1x2.jpg", videoURL: "https://v.example/a.mp4",
                               isLivePhoto: true, contentID: nil)]
        let gallery = FeedMedia.gallery(
            urls: ["https://image.coolapk.com/a-livepic@1x2.jpg", "https://image.coolapk.com/body@3x4.jpg"],
            items: known, contentID: "77", contentType: .article)
        XCTAssertEqual(gallery[0].videoURL, "https://v.example/a.mp4")
        XCTAssertEqual(gallery[0].contentID, "77")
        XCTAssertEqual(gallery[0].contentType, .article)
        XCTAssertEqual(gallery[1], FeedMedia(sourceURL: "https://image.coolapk.com/body@3x4.jpg", contentID: "77", contentType: .article))
        XCTAssertEqual(FeedMedia.gallery(urls: [], items: known), known)

        let article = entity(#"{"id": 5, "feedType": "feedArticle", "picArr": ["https://image.coolapk.com/p-uhdr@1x1.jpg"]}"#)
        let mapped = article.mediaItems(for: ["https://image.coolapk.com/cover@1x1.jpg", "https://image.coolapk.com/p-uhdr@1x1.jpg"])
        XCTAssertEqual(mapped.map(\.isHDR), [false, true])
        XCTAssertEqual(mapped.map(\.contentType), [.article, .feed])
    }
}

final class MotionPhotoTests: XCTestCase {
    private let jpegTail = Data([0xFF, 0xD9])
    private let video = Data([0, 0, 0, 24]) + Data("ftypmp42".utf8) + Data(repeating: 7, count: 12) + Data("mdat-payload".utf8)

    private func jpeg(xmp: String) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE1]) + Data(xmp.utf8) + Data(repeating: 0x55, count: 64) + jpegTail
    }

    private func containerXMP(videoLength: Int, trailing: Int = 0) -> String {
        """
        <x:xmpmeta><rdf:Description GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1">
        <Container:Directory><rdf:Seq>
        <rdf:li><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/></rdf:li>
        <rdf:li><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="\(videoLength)" Item:Padding="0"/></rdf:li>
        \(trailing > 0 ? "<rdf:li><Container:Item Item:Mime=\"application/octet-stream\" Item:Length=\"\(trailing)\"/></rdf:li>" : "")
        </rdf:Seq></Container:Directory></rdf:Description></x:xmpmeta>
        """
    }

    func testExtractsVideoDeclaredByContainerDirectory() throws {
        let file = jpeg(xmp: containerXMP(videoLength: video.count)) + video
        XCTAssertTrue(MotionPhoto.declaresVideo(file))
        let extracted = try XCTUnwrap(MotionPhoto.embeddedVideo(in: file))
        XCTAssertEqual(extracted.data, video)
        XCTAssertEqual(extracted.fileExtension, "mp4")
        XCTAssertEqual(MotionPhoto.embeddedVideoRange(in: file), file.count - video.count..<file.count)
    }

    func testItemsAfterTheVideoShiftItsOffset() throws {
        let extra = Data(repeating: 9, count: 10)
        let file = jpeg(xmp: containerXMP(videoLength: video.count, trailing: extra.count)) + video + extra
        let range = try XCTUnwrap(MotionPhoto.embeddedVideoRange(in: file))
        XCTAssertEqual(range.lowerBound, file.count - video.count - extra.count)
    }

    func testLegacyMicroVideoOffsetAndQuickTimeBrand() throws {
        let movie = Data([0, 0, 0, 20]) + Data("ftypqt  ".utf8) + Data(repeating: 1, count: 24)
        let file = jpeg(xmp: "<x:xmpmeta GCamera:MicroVideo=\"1\" GCamera:MicroVideoOffset=\"\(movie.count)\"/>") + movie
        let extracted = try XCTUnwrap(MotionPhoto.embeddedVideo(in: file))
        XCTAssertEqual(extracted.data, movie)
        XCTAssertEqual(extracted.fileExtension, "mov")
    }

    func testFallsBackToScanningWhenDeclarationIsWrong() throws {
        let file = jpeg(xmp: containerXMP(videoLength: 5)) + video
        XCTAssertEqual(try XCTUnwrap(MotionPhoto.embeddedVideo(in: file)).data, video)
        let undeclared = jpeg(xmp: "") + video
        XCTAssertFalse(MotionPhoto.declaresVideo(undeclared))
        XCTAssertEqual(MotionPhoto.embeddedVideo(in: undeclared)?.data, video)
    }

    /// 酷安图床返回的实况静态图保留了声明，但视频已被去掉。
    func testStrippedMotionPhotoHasNoVideo() {
        let stripped = jpeg(xmp: containerXMP(videoLength: 5_818_179))
        XCTAssertTrue(MotionPhoto.declaresVideo(stripped))
        XCTAssertNil(MotionPhoto.embeddedVideo(in: stripped))
    }

    func testIgnoresNonJPEGAndImageContainers() {
        XCTAssertNil(MotionPhoto.embeddedVideo(in: video))
        XCTAssertNil(MotionPhoto.embeddedVideo(in: Data()))
        let heic = Data([0, 0, 0, 24]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 24)
        XCTAssertNil(MotionPhoto.embeddedVideo(in: jpeg(xmp: "") + heic))
        // 切片的下标不从 0 开始也要正确。
        let padded = Data(repeating: 0, count: 5) + jpeg(xmp: containerXMP(videoLength: video.count)) + video
        XCTAssertEqual(MotionPhoto.embeddedVideo(in: padded.dropFirst(5))?.data, video)
    }
}
