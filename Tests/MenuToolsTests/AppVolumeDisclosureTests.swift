import Testing
@testable import MenuTools

@Test("音频高级页的自检与兼容性诊断可独立展开")
func audioAdvancedDisclosuresAreIndependent() {
    var state = AppVolumeAdvancedDisclosureState()
    #expect(!state.showsSelfCheck)
    #expect(!state.showsCompatibility)

    state.showsSelfCheck = true
    #expect(state.showsSelfCheck)
    #expect(!state.showsCompatibility)

    state.showsCompatibility = true
    state.showsSelfCheck = false
    #expect(!state.showsSelfCheck)
    #expect(state.showsCompatibility)
}
