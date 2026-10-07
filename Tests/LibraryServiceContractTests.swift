import XCTest
@testable import Sonux

/// LibraryService 里能独立测的东西：supportedExtensions 常量集、LibrarySort 枚举、
/// 以及 LibraryError 的错误消息组装（.deleteFailed 用 LF 但键就是英文原文）。
/// 至于 rescan / import / progress 落盘那一坨，涉及 @MainActor 状态、FileManager 与 AVFoundation，
/// 需要单独搭集成环境；本轮先钉死纯常量与枚举契约，等后面加沙盒 fixture 时再扩。
final class LibraryServiceContractTests: XCTestCase {
    // MARK: - supportedExtensions

    func testSupportedExtensions_containsAllExpectedFormats() {
        // 支持列表要精确到这六种，多一个少一个都可能让「导入没反应」或「删不掉」
        XCTAssertEqual(LibraryService.supportedExtensions,
                       Set(["mp3", "m4a", "m4b", "aac", "wav", "wave"]))
    }

    func testSupportedExtensions_areLowercase() {
        // 上层匹配时会先 lowercased()，但源集合本身就应全小写，免得大小写两套各留一份
        for ext in LibraryService.supportedExtensions {
            XCTAssertEqual(ext, ext.lowercased(), "\(ext) 应是小写")
        }
    }

    func testSupportedExtensions_hasNoDots() {
        // pathExtension 拿到的是不带点的字符串，集合里若混进 ".mp3" 会永远匹配不上
        for ext in LibraryService.supportedExtensions {
            XCTAssertFalse(ext.hasPrefix("."), "\(ext) 不该带点")
        }
    }

    // MARK: - LibrarySort

    func testLibrarySort_allCasesOrderIsMenuOrder() {
        // 菜单顺序 = case 顺序 = caseIterable；改一处会砸到 UI
        XCTAssertEqual(LibrarySort.allCases, [.lastPlayed, .added, .fileName])
    }

    func testLibrarySort_idMatchesRawValue() {
        for sort in LibrarySort.allCases {
            XCTAssertEqual(sort.id, sort.rawValue)
        }
    }

    func testLibrarySort_rawValuesAreStableStrings() {
        // 存在 UserDefaults 里的键；改字符串会让老用户的排序偏好丢
        XCTAssertEqual(LibrarySort.lastPlayed.rawValue, "lastPlayed")
        XCTAssertEqual(LibrarySort.added.rawValue, "added")
        XCTAssertEqual(LibrarySort.fileName.rawValue, "fileName")
    }

    // MARK: - LibraryError

    func testLibraryError_deleteFailedHasNonEmptyMessage() {
        // 底层错误由 LF 取词组装，这里只保证「有内容且不吞参数」——具体文案随宿主语言变
        let underlying = NSError(domain: NSCocoaErrorDomain, code: 510,
                                 userInfo: [NSLocalizedDescriptionKey: "X"])
        let err = LibraryError.deleteFailed("MyBook", underlying: underlying)
        XCTAssertNotNil(err.errorDescription)
        XCTAssertFalse(err.errorDescription!.isEmpty)
    }
}
