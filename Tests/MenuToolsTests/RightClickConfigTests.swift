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
