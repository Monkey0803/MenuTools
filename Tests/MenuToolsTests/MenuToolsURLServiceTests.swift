import Foundation
import Testing
@testable import MenuTools

@Test("布局 URL 名使用 kebab-case 且能往返")
func menuToolsURLKebabNamesRoundTrip() {
    #expect(WindowLayoutURLName.name(for: .leftHalf) == "left-half")
    #expect(WindowLayoutURLName.layout(from: "left-half") == .leftHalf)
    // 大小写与空白容错
    #expect(WindowLayoutURLName.layout(from: "  LEFT-HALF ") == .leftHalf)
    #expect(WindowLayoutURLName.layout(from: "") == nil)
    #expect(WindowLayoutURLName.layout(from: "not-a-layout") == nil)

    // 每个布局都必须能往返，否则脚本调用会因为拼写差异静默失效
    for layout in WindowLayout.allCases {
        #expect(WindowLayoutURLName.layout(from: WindowLayoutURLName.name(for: layout)) == layout)
    }
}

@Test("深链解析现有的窗口、预设与设置入口")
func menuToolsURLParsesWindowPresetSettings() throws {
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://window?layout=left-half"))) == .layout(.leftHalf))
    // 与 Rectangle 的 execute-action 习惯一致
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://action?name=left-half"))) == .layout(.leftHalf))
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://preset?name=%E5%BC%80%E5%8F%91"))) == .preset("开发"))
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://settings?tab=runtime-status"))) == .settings(.runtimeStatus))

    // 拒绝：别的 scheme、未知 host、缺参数、未知取值
    #expect(MenuToolsURL.action(for: try #require(URL(string: "https://window?layout=left-half"))) == nil)
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://unknown?name=x"))) == nil)
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://window"))) == nil)
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://settings?tab=nope"))) == nil)
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://preset?name=%20%20"))) == nil)
}

@Test("深链新增场景与快捷操作入口")
func menuToolsURLParsesScenesAndQuickActions() throws {
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://scene?name=work"))) == .scene(.work))
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://scene?name=DEMO"))) == .scene(.demo))
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://scene"))) == nil)
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://scene?name=nope"))) == nil)

    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://quick-action?name=lock-screen"))) == .quickAction(.lockScreen))
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://quick-action?name=flush-dns"))) == .quickAction(.flushDNS))
    // host 大小写不敏感，驼峰写法也接受
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://quickAction?name=lockScreen"))) == .quickAction(.lockScreen))
    #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://quick-action"))) == nil)

    // 每个快捷操作都能解析，避免新增动作时漏配
    for action in QuickAction.allCases {
        let name = WindowLayoutURLName.kebab(action.rawValue)
        #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://quick-action?name=\(name)"))) == .quickAction(action))
    }
    // 每个场景同样
    for scene in ScenePreset.allCases {
        #expect(MenuToolsURL.action(for: try #require(URL(string: "menutools://scene?name=\(scene.rawValue)"))) == .scene(scene))
    }
}

@Test("kebab 转换不拆开连续大写（缩写词）")
func menuToolsURLKebabHandlesAcronyms() {
    #expect(WindowLayoutURLName.kebab("leftHalf") == "left-half")
    #expect(WindowLayoutURLName.kebab("runtimeStatus") == "runtime-status")
    #expect(WindowLayoutURLName.kebab("openSystemSettings") == "open-system-settings")
    // 缩写词整体小写，而不是拆成 flush-d-n-s
    #expect(WindowLayoutURLName.kebab("flushDNS") == "flush-dns")
    #expect(WindowLayoutURLName.kebab("DNSValue") == "dns-value")
    #expect(WindowLayoutURLName.kebab("already-kebab") == "already-kebab")
}
