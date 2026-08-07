import Foundation
import Testing
@testable import MenuTools

@Test("右键配置通知可以解码为配置")
func rightClickNotificationDecodesConfig() throws {
    let expected = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false])
    let data = try JSONEncoder().encode(expected)
    let payload = try #require(String(data: data, encoding: .utf8))
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: payload
    )

    #expect(RightClickConfigStore.decode(notification) == expected)
}

@Test("无效右键配置通知会被忽略")
func invalidRightClickNotificationIsIgnored() {
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: "not-json"
    )

    #expect(RightClickConfigStore.decode(notification) == nil)
}

@Test("有效右键配置通知会替换过期状态")
func validRightClickNotificationReplacesStaleConfig() throws {
    let stale = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: true])
    let replacement = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false])
    let data = try JSONEncoder().encode(replacement)
    let payload = try #require(String(data: data, encoding: .utf8))
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: payload
    )

    #expect(RightClickConfigNotification.applying(notification, to: stale) == replacement)
}

@Test("无效右键配置通知会保留当前状态")
func invalidRightClickNotificationPreservesCurrentConfig() {
    let current = RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false])
    let notification = Notification(
        name: Notification.Name(RightClickConfigStore.didChangeNotification),
        object: "not-json"
    )

    #expect(RightClickConfigNotification.applying(notification, to: current) == current)
}
