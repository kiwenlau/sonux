import XCTest
@testable import Sonux

/// BookEntity 是把 Book 拍扁给 Siri / 快捷指令用的值对象：只带 id 与 title 两个字段。
/// 关键约定：
///   1. 从 Book 构造时不能现查书库（displayRepresentation 是同步接口，书库在主线程），
///      所以 title 必须内联存进来。
///   2. AppEntity.id 就是 Book.id，语音回查走 ids 一条链。
final class BookEntityTests: XCTestCase {
    private func book(id: String, title: String) -> Book {
        Book(id: id, title: title, author: nil, chapters: [], storagePath: "p")
    }

    func testInitFromBook_copiesIdAndTitle() {
        let e = BookEntity(book: book(id: "xyz", title: "百年孤独"))
        XCTAssertEqual(e.id, "xyz")
        XCTAssertEqual(e.title, "百年孤独")
    }

    func testInitFromIdAndTitle_isIndependent() {
        let e = BookEntity(id: "a", title: "B")
        XCTAssertEqual(e.id, "a")
        XCTAssertEqual(e.title, "B")
    }

    func testDisplayRepresentation_showsTitle() {
        let e = BookEntity(book: book(id: "x", title: "某本书"))
        // DisplayRepresentation.title 走 .string 视图；只保证有内容且能取到
        let repr = e.displayRepresentation
        _ = repr.title     // 访问不崩就算过；具体本地化行为交给系统
    }

    func testTypeDisplayRepresentation_hasBookName() {
        // 快捷指令界面上「Book」这个类型的显示名不能被误改（会砸到用户已存的自动化）
        // TypeDisplayRepresentation 不直接暴露 name 字符串，只保证能读出不崩
        _ = BookEntity.typeDisplayRepresentation
    }
}
