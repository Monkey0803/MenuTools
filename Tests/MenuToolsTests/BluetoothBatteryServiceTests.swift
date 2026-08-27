import Foundation
import Testing
@testable import MenuTools

@Test("system_profiler 可以解析 AirPods 左右耳和充电盒电量")
func parsesAirPodsBatteryFromSystemProfiler() throws {
    let data = try #require(
        """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "AirPods Pro": {
                    "device_address": "EC:46:54:2D:16:AB",
                    "device_batteryLevelLeft": "100%",
                    "device_batteryLevelRight": "74%",
                    "device_batteryLevelCase": "63%",
                    "device_minorType": "Headphones"
                  }
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)
    )

    let devices = BluetoothSystemProfilerParser.parse(data: data)
    let airPods = try #require(devices.first)

    #expect(airPods.id == "EC:46:54:2D:16:AB")
    #expect(airPods.name == "AirPods Pro")
    #expect(airPods.leftPercent == 100)
    #expect(airPods.rightPercent == 74)
    #expect(airPods.casePercent == 63)
    #expect(airPods.singlePercent == nil)
    #expect(airPods.isAudio)
}

@Test("补充数据只填充缺失电量并按不同格式的蓝牙地址合并")
func mergesPartialBluetoothBatteryByNormalizedAddress() throws {
    let primary = BluetoothDeviceBattery(
        id: "ec-46-54-2d-16-ab",
        name: "AirPods Pro",
        leftPercent: nil,
        rightPercent: 74,
        casePercent: nil,
        singlePercent: nil
    )
    var supplemental = BluetoothDeviceBattery(
        id: "EC:46:54:2D:16:AB",
        name: "AirPods Pro",
        leftPercent: 100,
        rightPercent: 72,
        casePercent: 63,
        singlePercent: nil
    )
    supplemental.isAudio = true

    let merged = BluetoothBatteryMerger.merge(
        primary: [primary],
        supplemental: [supplemental]
    )
    let airPods = try #require(merged.first)

    #expect(merged.count == 1)
    #expect(airPods.leftPercent == 100)
    #expect(airPods.rightPercent == 74)
    #expect(airPods.casePercent == 63)
    #expect(airPods.isAudio)
}
