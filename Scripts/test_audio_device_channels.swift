import CoreAudio
import Foundation

/// 打印每个音频设备**当前**的输入/输出声道数，用来定位「输入 2 声道 / 输出 1 声道」
/// 这类 App 音量接管失败的原因。
///
/// 蓝牙耳机在音乐模式（A2DP）下输出是 2 声道，一旦有 App 占用麦克风（通话、会议），
/// 系统会把它切成通话模式（HFP），同一个设备的输出就只剩 1 个声道，而进程 tap 固定是
/// 立体声混音——两边声道数在切换前后并不稳定。
///
/// 用法：
///   swift Scripts/test_audio_device_channels.swift
///
/// 只读取 CoreAudio 属性，不建 tap、不改任何系统状态，运行期间也不会影响正在播放的音频。

private func fourCC(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    let characters = bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
    return String(characters)
}

private func systemObject() -> AudioObjectID {
    AudioObjectID(kAudioObjectSystemObject)
}

private func readScalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<T>.alignment
    )
    defer { value.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
    return value.load(as: T.self)
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeUnretainedValue() as String?
}

/// 设备在某个 scope 上的数据流布局：每个流几个声道。
private func channelCounts(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
        return []
    }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return [] }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.map { Int($0.mNumberChannels) }
}

private func describe(_ counts: [Int]) -> String {
    counts.isEmpty ? "无" : counts.map { "\($0)ch" }.joined(separator: "+")
}

private func deviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject(), &address, 0, nil, &size) == noErr else { return [] }
    var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject(), &address, 0, nil, &size, &values) == noErr else {
        return []
    }
    return values
}

let defaultOutput: AudioDeviceID = readScalar(
    systemObject(),
    kAudioHardwarePropertyDefaultOutputDevice
) ?? 0
let defaultInput: AudioDeviceID = readScalar(
    systemObject(),
    kAudioHardwarePropertyDefaultInputDevice
) ?? 0

var monoOutputDevices = 0
for device in deviceIDs() {
    let name = readString(device, kAudioObjectPropertyName) ?? "?"
    let uid = readString(device, kAudioDevicePropertyDeviceUID) ?? "?"
    let transport: UInt32 = readScalar(device, kAudioDevicePropertyTransportType) ?? 0
    let outputs = channelCounts(device, scope: kAudioDevicePropertyScopeOutput)
    let inputs = channelCounts(device, scope: kAudioDevicePropertyScopeInput)
    guard !outputs.isEmpty || !inputs.isEmpty else { continue }

    let roles = [
        device == defaultOutput ? "默认输出" : nil,
        device == defaultInput ? "默认输入" : nil
    ].compactMap { $0 }.joined(separator: "，")
    let outputChannels = outputs.reduce(0, +)
    if device == defaultOutput, outputChannels == 1 { monoOutputDevices += 1 }

    print("\(name) [\(fourCC(transport))] 输出=\(describe(outputs)) 输入=\(describe(inputs)) \(roles)")
    print("    uid=\(uid) id=\(device)")
}

if monoOutputDevices > 0 {
    print("")
    print("注意：默认输出设备当前只有 1 个声道（蓝牙耳机多半处在通话模式）。")
    print("进程 tap 固定是立体声，App 音量会按声道映射把它下混成单声道。")
}
