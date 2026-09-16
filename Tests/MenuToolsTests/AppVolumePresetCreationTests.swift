import Foundation
import Testing
@testable import MenuTools

// MARK: - 音量预设的新建草稿

@Test("新建预设默认收起：进入预设页看到的是预设列表，而不是空白新建表单")
func presetCreationDraftStartsCollapsed() {
    let draft = AppVolumePresetCreationDraft()

    #expect(draft.isExpanded == false)
    #expect(draft.name.isEmpty)
    #expect(draft.appIdentifiers.isEmpty)

    // 收起状态下即使名称非空也不能保存，避免列表里的回车落到隐藏的表单上。
    var named = draft
    named.name = "夜间"
    #expect(named.canSave == false)
}

@Test("点「＋」展开新建表单会清掉上一次的选择")
func presetCreationDraftBeginClearsPreviousSelection() {
    var draft = AppVolumePresetCreationDraft()
    draft.name = "上一个预设"
    draft.appIdentifiers = ["com.apple.Safari"]

    draft.begin()

    #expect(draft.isExpanded)
    #expect(draft.name.isEmpty)
    #expect(draft.appIdentifiers.isEmpty)
}

@Test("空白名称不能保存，补齐名称后才能保存")
func presetCreationDraftRejectsBlankName() {
    var draft = AppVolumePresetCreationDraft()
    draft.begin()

    #expect(draft.canSave == false)

    draft.name = "   "
    #expect(draft.canSave == false)

    draft.name = " 夜间 "
    #expect(draft.canSave)
}

@Test("保存或取消后收起并清空，草稿不会残留到下一次新建")
func presetCreationDraftFinishResets() {
    var draft = AppVolumePresetCreationDraft()
    draft.begin()
    draft.name = "夜间"
    draft.appIdentifiers = ["com.apple.Safari"]

    draft.finish()

    #expect(draft.isExpanded == false)
    #expect(draft.name.isEmpty)
    #expect(draft.appIdentifiers.isEmpty)
}
