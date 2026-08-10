import Foundation
import Testing
@testable import MenuTools

@Test("电池健康解析支持嵌套 system_profiler 数据")
func batteryHealthParserReadsNestedData() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "SPPowerDataType": [[
            "_name": "sppower_battery_health_info",
            "Battery Information": [
                "Condition": "Normal",
                "Cycle Count": 42,
                "Maximum Capacity": 96,
                "State of Charge (%)": 83,
                "Charging": "Yes"
            ]
        ]]
    ])

    let snapshot = try #require(BatteryHealthParser.parse(data: data))
    #expect(snapshot.condition == "Normal")
    #expect(snapshot.cycleCount == 42)
    #expect(snapshot.healthPercent == 96)
    #expect(snapshot.currentPercent == 83)
    #expect(snapshot.isCharging)
}

@Test("无电池数据时静默返回 nil")
func batteryHealthParserReturnsNilWithoutBattery() throws {
    let data = try JSONSerialization.data(withJSONObject: ["SPPowerDataType": []])
    #expect(BatteryHealthParser.parse(data: data) == nil)
}
