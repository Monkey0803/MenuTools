import Foundation
import Testing
@testable import MenuTools

@Test("剪贴板历史按最新优先并限制容量")
func historyKeepsNewestItemsWithinLimit() {
    var history = ClipboardHistoryBuffer(limit: 2)
    let now = Date(timeIntervalSince1970: 100)

    history.insert(.text("第一条"), now: now)
    history.insert(.text("第二条"), now: now.addingTimeInterval(1))
    history.insert(.text("第三条"), now: now.addingTimeInterval(2))

    #expect(history.items.map(\.content) == [.text("第三条"), .text("第二条")])
}

@Test("重复内容会移动到历史顶部而不是创建重复项")
func historyDeduplicatesContent() {
    var history = ClipboardHistoryBuffer(limit: 3)
    let now = Date(timeIntervalSince1970: 100)

    history.insert(.text("重复"), now: now)
    history.insert(.text("其他"), now: now.addingTimeInterval(1))
    history.insert(.text("重复"), now: now.addingTimeInterval(2))

    #expect(history.items.map(\.content) == [.text("重复"), .text("其他")])
    #expect(history.items[0].capturedAt == now.addingTimeInterval(2))
}

@Test("固定项目不会被容量淘汰")
func historyPreservesPinnedItems() {
    var history = ClipboardHistoryBuffer(limit: 2)
    let now = Date(timeIntervalSince1970: 100)

    let pinned = history.insert(.text("固定"), now: now)
    #expect(pinned != nil)
    history.togglePinned(id: pinned!.id)
    history.insert(.text("普通一"), now: now.addingTimeInterval(1))
    history.insert(.text("普通二"), now: now.addingTimeInterval(2))

    #expect(history.items.map(\.content) == [.text("普通二"), .text("固定")])
    #expect(history.items[1].isPinned)
}

@Test("验证码和密码内容会标记为敏感并在期限后移除")
func sensitiveTextExpires() {
    var history = ClipboardHistoryBuffer(limit: 5, sensitiveLifetime: 60)
    let now = Date(timeIntervalSince1970: 100)

    let code = history.insert(.text("123456"), now: now)
    #expect(code?.expiresAt == now.addingTimeInterval(60))
    #expect(history.items.count == 1)

    history.pruneExpired(now: now.addingTimeInterval(60))

    #expect(history.items.isEmpty)
}

@Test("图片内容可以加入历史且不会被当作敏感文本")
func imageContentIsRetained() {
    var history = ClipboardHistoryBuffer(limit: 2)
    let data = Data([0, 1, 2, 3])

    let item = history.insert(.image(data), now: Date())

    #expect(item?.content == .image(data))
    #expect(item?.expiresAt == nil)
}

@Test("删除和清空操作只影响对应历史项目")
func historyRemovesRequestedItems() {
    var history = ClipboardHistoryBuffer(limit: 5)
    let now = Date(timeIntervalSince1970: 100)
    let pinned = history.insert(.text("固定"), now: now)
    history.insert(.text("普通"), now: now.addingTimeInterval(1))
    history.togglePinned(id: pinned!.id)

    history.remove(id: pinned!.id)
    history.clearUnpinned()

    #expect(history.items.isEmpty)
}

@Test("清空剪贴板历史会移除普通和固定项目")
func historyClearRemovesAllItems() {
    var history = ClipboardHistoryBuffer(limit: 5)
    let pinned = history.insert(.text("固定"), now: Date())
    history.insert(.text("普通"), now: Date())
    history.togglePinned(id: pinned!.id)

    history.clearAll()

    #expect(history.items.isEmpty)
}
