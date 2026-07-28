#!/usr/bin/swift
// 验证：通过 CoreBluetooth 读取系统已连接 BLE 设备的 GATT 电池服务 (180F/2A19)
import CoreBluetooth
import Foundation

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var pending = 0
    var retained: [CBPeripheral] = []   // 必须强引用，否则连接会被取消

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("central state = \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180F")])
        print("系统已连接且带电池服务的 BLE 设备：\(connected.count) 个")
        pending = connected.count
        retained = connected
        if connected.isEmpty { exit(0) }
        for p in connected {
            print("  - \(p.name ?? "?") [\(p.identifier)]")
            p.delegate = self
            central.connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: "180F")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("  ✗ 连接失败 \(peripheral.name ?? "?"): \(error?.localizedDescription ?? "?")")
        finishOne()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "180F") }) else {
            print("  ✗ \(peripheral.name ?? "?") 无电池服务"); finishOne(); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "2A19")], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let char = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "2A19") }) else {
            print("  ✗ \(peripheral.name ?? "?") 无电量特征"); finishOne(); return
        }
        peripheral.readValue(for: char)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value, let level = data.first {
            print("  ✓ \(peripheral.name ?? "?") 电量 = \(level)%")
        } else {
            print("  ✗ \(peripheral.name ?? "?") 读取失败: \(error?.localizedDescription ?? "?")")
        }
        finishOne()
    }

    func finishOne() {
        pending -= 1
        if pending <= 0 { print("PASS: 探测完成"); exit(0) }
    }
}

let probe = Probe()
probe.central = CBCentralManager(delegate: probe, queue: nil)
RunLoop.main.run(until: Date().addingTimeInterval(10))
print("TIMEOUT: 10 秒内未完成全部读取")
