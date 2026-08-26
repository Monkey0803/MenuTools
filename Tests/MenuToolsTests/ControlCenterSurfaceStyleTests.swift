import Testing
@testable import MenuTools

@Test("选中的控制中心按钮使用凸起玻璃层次")
func selectedControlCenterSurfaceUsesRaisedGlassLayers() {
    let idle = ControlCenterSurfaceStyle.resolve(selected: false, highlighted: false)
    let selected = ControlCenterSurfaceStyle.resolve(selected: true, highlighted: false)

    #expect(selected.specularOpacity >= 0.35)
    #expect(selected.lowerRimOpacity >= 0.25)
    #expect(selected.shadowRadius > idle.shadowRadius)
    #expect(selected.shadowY > idle.shadowY)
}
