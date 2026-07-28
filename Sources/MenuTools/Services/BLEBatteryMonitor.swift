import CoreBluetooth
import Foundation

/// GATT 标准电池服务与电量特征（nonisolated 回调中也可安全构造）
private let batteryServiceID = "180F"
private let batteryLevelID = "2A19"

/// 通过 CoreBluetooth 读取系统已连接 BLE 设备的标准 GATT 电池服务 (180F / 2A19)
/// 覆盖罗技等第三方 BLE 键鼠；AirPods 类设备由 BluetoothBatteryService (IORegistry) 负责
@MainActor
final class BLEBatteryMonitor: NSObject, ObservableObject {
    static let shared = BLEBatteryMonitor()

    @Published private(set) var devices: [BluetoothDeviceBattery] = []

    private var central: CBCentralManager?
    private var retained: [UUID: CBPeripheral] = [:]   // 必须强引用，否则连接会被系统取消
    private var results: [UUID: BluetoothDeviceBattery] = [:]

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// 重新枚举系统已连接的 BLE 设备并读取电量
    func refresh() {
        guard let central, central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: batteryServiceID)])
        // 移除已断开设备的旧数据
        let activeIDs = Set(connected.map(\.identifier))
        results = results.filter { activeIDs.contains($0.key) }
        retained = retained.filter { activeIDs.contains($0.key) }
        publish()

        for peripheral in connected {
            retained[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([CBUUID(string: batteryServiceID)])
            } else {
                central.connect(peripheral)
            }
        }
    }

    private func record(id: UUID, name: String, percent: Int) {
        results[id] = BluetoothDeviceBattery(
            id: id.uuidString,
            name: name,
            leftPercent: nil,
            rightPercent: nil,
            casePercent: nil,
            singlePercent: percent
        )
        publish()
    }

    private func publish() {
        devices = results.values.sorted { $0.name < $1.name }
    }
}

// CBCentralManager 使用主队列回调，delegate 方法内可安全切回 MainActor
extension BLEBatteryMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let poweredOn = central.state == .poweredOn
        MainActor.assumeIsolated {
            if poweredOn {
                refresh()
            } else {
                results.removeAll()
                publish()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: batteryServiceID)])
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: batteryServiceID) }) else { return }
        peripheral.discoverCharacteristics([CBUUID(string: batteryLevelID)], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == CBUUID(string: batteryLevelID) }) else { return }
        peripheral.readValue(for: characteristic)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let level = characteristic.value?.first, level <= 100 else { return }
        let id = peripheral.identifier
        let name = peripheral.name ?? L("bt.device")
        MainActor.assumeIsolated {
            record(id: id, name: name, percent: Int(level))
        }
    }
}
