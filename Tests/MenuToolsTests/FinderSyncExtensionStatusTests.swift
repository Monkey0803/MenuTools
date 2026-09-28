import Testing
@testable import MenuTools

struct FinderSyncExtensionStatusTests {
    @Test func finderAPIEnabledTakesPrecedence() {
        let state = FinderSyncExtensionStatus.resolve(
            finderAPIEnabled: true,
            pluginRegistryOutput: "- com.qoder.menutools.finder-sync"
        )

        #expect(state == .enabled)
    }

    @Test func registeredPluginIsTreatedAsAvailableWhenFinderAPIMisreports() {
        let state = FinderSyncExtensionStatus.resolve(
            finderAPIEnabled: false,
            pluginRegistryOutput: "+    com.qoder.menutools.finder-sync(1.0.0)"
        )

        #expect(state == .registered)
    }

    @Test func disabledPluginIsReportedAsDisabled() {
        let state = FinderSyncExtensionStatus.resolve(
            finderAPIEnabled: false,
            pluginRegistryOutput: "-    com.qoder.menutools.finder-sync(1.0.0)"
        )

        #expect(state == .disabled)
    }

    @Test func unavailableRegistryLeavesStatusUnknown() {
        let state = FinderSyncExtensionStatus.resolve(
            finderAPIEnabled: false,
            pluginRegistryOutput: nil
        )

        #expect(state == .unknown)
    }
}
