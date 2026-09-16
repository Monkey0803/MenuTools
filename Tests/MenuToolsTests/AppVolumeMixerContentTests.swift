import Foundation
import Testing
@testable import MenuTools

@Test("调音台按播放状态分区且保留服务提供的排序")
func mixerContentPartitionsWithoutReordering() {
    let sessions = [mixerSession("B", active: true), mixerSession("C", active: false),
                    mixerSession("A", active: true), mixerSession("D", active: false)]
    let content = AppVolumeMixerContent(sessions: sessions, searchQuery: "", filter: .all, group: nil)

    #expect(content.active.map(\.id) == ["B", "A"])
    #expect(content.remembered.map(\.id) == ["C", "D"])
    #expect(!content.showsRemembered(userExpanded: false))
    #expect(content.showsRemembered(userExpanded: true))
}

@Test("搜索与收藏或分组筛选时，匹配的已记住 App 自动可见")
func mixerContentRevealsRememberedMatches() {
    let sessions = [mixerSession("Music", active: false)]
    let search = AppVolumeMixerContent(sessions: sessions, searchQuery: " Music ", filter: .all, group: nil)
    let favorites = AppVolumeMixerContent(sessions: sessions, searchQuery: "", filter: .favorites, group: nil)
    let group = AppVolumeMixerContent(sessions: sessions, searchQuery: "", filter: .all, group: .meeting)
    let whitespace = AppVolumeMixerContent(sessions: sessions, searchQuery: " \n ", filter: .all, group: nil)

    #expect(search.showsRemembered(userExpanded: false))
    #expect(favorites.showsRemembered(userExpanded: false))
    #expect(group.showsRemembered(userExpanded: false))
    #expect(!whitespace.showsRemembered(userExpanded: false))
}

@Test("空列表区分没有播放中的应用与搜索筛选无结果")
func mixerContentDistinguishesEmptyStates() {
    let idle = AppVolumeMixerContent(sessions: [], searchQuery: "", filter: .all, group: nil)
    let searching = AppVolumeMixerContent(sessions: [], searchQuery: "Safari", filter: .all, group: nil)
    let favorites = AppVolumeMixerContent(sessions: [], searchQuery: "", filter: .favorites, group: nil)

    #expect(!idle.hasNarrowingFilter)
    #expect(searching.hasNarrowingFilter)
    #expect(favorites.hasNarrowingFilter)
    #expect(!searching.showsRemembered(userExpanded: true))
}

private func mixerSession(_ id: String, active: Bool) -> AppAudioSession {
    AppAudioSession(
        rootBundleID: id, displayName: id, bundleURL: nil, processObjectIDs: [],
        audioBundleIDs: [], isRunningOutput: active, volume: 1,
        lastAdjustedAt: .distantPast, errorMessage: nil
    )
}

@Test("音量设置页有五个一级页且默认进入调音台")
func settingsPagesCoverFourTasks() {
    // 「高级」是后拆出来的：会议闪避、睡眠定时、自检与诊断从设置页移过去，
    // 否则设置页要滚近两屏。
    #expect(AppVolumeSettingsPage.allCases == [.mixer, .devices, .scenes, .settings, .advanced])
    #expect(AppVolumeSettingsPage.allCases.first == .mixer)

    for page in AppVolumeSettingsPage.allCases {
        #expect(!page.titleKey.isEmpty)
        #expect(!page.symbol.isEmpty)
        #expect(page.id == page)
    }
    // 每个页面的文案键唯一
    #expect(Set(AppVolumeSettingsPage.allCases.map(\.titleKey)).count == 5)
}

@Test("空态按是否有筛选给出不同文案键")
func mixerContentEmptyStateKeys() {
    let idle = AppVolumeMixerContent(sessions: [], searchQuery: "", filter: .all, group: nil)
    let filtered = AppVolumeMixerContent(sessions: [], searchQuery: "Safari", filter: .all, group: nil)

    #expect(idle.emptyStateKey == "volume.empty.idle")
    #expect(filtered.emptyStateKey == "volume.empty.filtered")
    // 有已记住的 App 时才显示该分区
    let withRemembered = AppVolumeMixerContent(
        sessions: [mixerSession("Music", active: false)],
        searchQuery: "",
        filter: .all,
        group: nil
    )
    #expect(!withRemembered.showsRemembered(userExpanded: false))
    #expect(withRemembered.showsRemembered(userExpanded: true))
}
