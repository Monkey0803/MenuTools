import Foundation
import Testing
@testable import MenuTools

@Test("后台发现新版本会记录为待处理提醒")
@MainActor
func updateReminderNotesAvailableVersion() {
    let reminder = AppUpdateReminder()

    #expect(!reminder.hasUnseenUpdate)

    reminder.noteAvailable(version: "1.1.1", notes: "修复若干问题")

    #expect(reminder.hasUnseenUpdate)
    #expect(reminder.availableVersion == "1.1.1")
    #expect(reminder.availableNotes == "修复若干问题")
}

@Test("用户处理后会收起提醒")
@MainActor
func updateReminderAcknowledges() {
    let reminder = AppUpdateReminder()
    reminder.noteAvailable(version: "1.1.1", notes: nil)

    reminder.acknowledge()

    #expect(!reminder.hasUnseenUpdate)
    #expect(reminder.availableVersion == nil)
    #expect(reminder.availableNotes == nil)
}

@Test("新的版本会覆盖旧的待处理版本")
@MainActor
func updateReminderReplacesOlderVersion() {
    let reminder = AppUpdateReminder()
    reminder.noteAvailable(version: "1.1.1", notes: "旧说明")

    reminder.noteAvailable(version: "1.2.0", notes: "新说明")

    #expect(reminder.availableVersion == "1.2.0")
    #expect(reminder.availableNotes == "新说明")
}

@Test("空版本号与空说明会被忽略或归一化")
@MainActor
func updateReminderIgnoresEmptyInput() {
    let reminder = AppUpdateReminder()

    reminder.noteAvailable(version: "   ", notes: "说明")
    #expect(!reminder.hasUnseenUpdate)

    reminder.noteAvailable(version: "1.1.1", notes: "   ")
    #expect(reminder.availableVersion == "1.1.1")
    #expect(reminder.availableNotes == nil)
}

@Test("共享实例全局唯一")
@MainActor
func updateReminderSharedInstanceIsSingleton() {
    #expect(AppUpdateReminder.shared === AppUpdateReminder.shared)
}
