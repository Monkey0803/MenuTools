import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// 独立验证 Core Audio Process Tap 能否完成：捕获目标 App、静音原音、施加增益、
/// 通过当前输出设备重放，并在退出时恢复原始音频。
///
/// 同时打印 tap 输入与输出设备的真实缓冲布局，用来确认「输入 2 声道 / 输出 1 声道」
/// 这类组合（蓝牙耳机进通话模式后输出只剩 1 个声道）到底长什么样。
///
/// 用法：
///   swift Scripts/test_app_volume_tap.swift <Bundle ID 前缀> [增益 0...1] [秒数]
///
/// 示例：
///   swift Scripts/test_app_volume_tap.swift com.google.Chrome 0.37 12

private enum TapProbeError: LocalizedError {
    case usage
    case noMatchingProcess(String)
    case coreAudio(String, OSStatus)
    case unsupportedFormat(AudioStreamBasicDescription)
    case incompatibleBuffers

    var errorDescription: String? {
        switch self {
        case .usage:
            return "用法：swift Scripts/test_app_volume_tap.swift <Bundle ID 前缀> [增益 0...1] [秒数]"
        case .noMatchingProcess(let bundleID):
            return "未找到正在输出音频的进程：\(bundleID)"
        case .coreAudio(let operation, let status):
            return "\(operation)失败，OSStatus=\(status)（\(UInt32(bitPattern: status).fourCC)）"
        case .unsupportedFormat(let format):
            return "验证脚本当前只处理 Float32 PCM，实际格式：\(format.debugSummary)"
        case .incompatibleBuffers:
            return "Tap 输入没有可用音频数据，未进行重放"
        }
    }
}

/// 声道布局：把交错缓冲里的多个声道拆开计数，和产品代码判定一致。
private enum ProbeBufferLayout {
    static func totalChannels(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        buffers.reduce(0) { $0 + max(Int($1.mNumberChannels), 1) }
    }

    static func accessor(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        channel: Int
    ) -> (index: Int, offset: Int, stride: Int)? {
        guard channel >= 0 else { return nil }
        var remaining = channel
        for index in buffers.indices {
            let channels = max(Int(buffers[index].mNumberChannels), 1)
            if remaining < channels {
                return (index, remaining, channels)
            }
            remaining -= channels
        }
        return nil
    }

    static func frames(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        var frames = Int.max
        for buffer in buffers {
            let channels = max(Int(buffer.mNumberChannels), 1)
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        }
        return frames == Int.max ? 0 : frames
    }

    /// 输出声道 `channel` 的来源声道区间；与产品代码的 AppVolumeChannelMap 保持一致。
    static func sourceRange(
        outputChannel channel: Int,
        inputChannels: Int,
        outputChannels: Int
    ) -> Range<Int> {
        guard inputChannels > 0, outputChannels > 0, channel >= 0, channel < outputChannels else {
            return 0..<0
        }
        if inputChannels == outputChannels { return channel..<(channel + 1) }
        if inputChannels > outputChannels {
            let start = channel * inputChannels / outputChannels
            let end = max((channel + 1) * inputChannels / outputChannels, start + 1)
            return start..<min(end, inputChannels)
        }
        guard inputChannels == 1 || channel < inputChannels else { return 0..<0 }
        return inputChannels == 1 ? 0..<1 : channel..<(channel + 1)
    }

    static func describe(_ buffers: UnsafeMutableAudioBufferListPointer) -> String {
        let perBuffer = buffers.map { "\(max(Int($0.mNumberChannels), 1))ch/\($0.mDataByteSize)B" }
        return "\(buffers.count) 个缓冲 [\(perBuffer.joined(separator: ", "))]"
            + " 共 \(totalChannels(buffers)) 声道、\(frames(buffers)) 帧"
    }
}

private struct ProbeProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
}

private final class ProbeState: @unchecked Sendable {
    let targetGain: Atomic<Float>
    let callbackStarted = Atomic(false)
    let layoutReported = Atomic(false)
    let invalidCallbackCount = Atomic(0)
    let callbackFailed = Atomic(false)

    init(gain: Float) {
        targetGain = Atomic(gain)
    }
}

private final class TapProbe {
    private var tapID = kAudioObjectUnknown
    private var aggregateDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.qoder.menutools.tap-probe", qos: .userInteractive)
    private let state: ProbeState

    init(gain: Float) {
        state = ProbeState(gain: gain)
    }

    deinit {
        stop()
    }

    func start(processes: [ProbeProcess]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes.map(\.objectID))
        description.uuid = UUID()
        description.name = "MenuTools App Volume Probe"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.isProcessRestoreEnabled = true
        description.bundleIDs = Array(Set(processes.map(\.bundleID))).sorted()
        guard description.isProcessRestoreEnabled,
              Set(description.bundleIDs) == Set(processes.map(\.bundleID)) else {
            throw TapProbeError.coreAudio("配置 Process Tap 自动恢复", kAudioHardwareIllegalOperationError)
        }

        try require(
            AudioHardwareCreateProcessTap(description, &tapID),
            "创建 Process Tap"
        )

        let tapFormat: AudioStreamBasicDescription = try readScalar(
            object: tapID,
            selector: kAudioTapPropertyFormat
        )
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            throw TapProbeError.unsupportedFormat(tapFormat)
        }

        let outputDevice: AudioDeviceID = try readScalar(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        let outputUID = try readString(
            object: outputDevice,
            selector: kAudioDevicePropertyDeviceUID
        )

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MenuTools App Volume Probe",
            kAudioAggregateDeviceUIDKey: "com.qoder.menutools.tap-probe.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        try require(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            ),
            "创建聚合设备"
        )

        var currentGain = state.targetGain.load(ordering: .relaxed)
        let state = self.state

        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            state.callbackStarted.store(true, ordering: .relaxed)
            if !state.layoutReported.exchange(true, ordering: .relaxed) {
                // 只在首个回调打印一次真实缓冲布局：这是判断「声道数不一致」的依据。
                let inputs = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inputData)
                )
                let outputs = UnsafeMutableAudioBufferListPointer(outputData)
                print("真实布局 · 输入：\(ProbeBufferLayout.describe(inputs))")
                print("真实布局 · 输出：\(ProbeBufferLayout.describe(outputs))")
                let inputChannels = ProbeBufferLayout.totalChannels(inputs)
                let outputChannels = ProbeBufferLayout.totalChannels(outputs)
                if inputChannels > 0, outputChannels > 0 {
                    let ranges = (0..<outputChannels).map { channel in
                        ProbeBufferLayout
                            .sourceRange(
                                outputChannel: channel,
                                inputChannels: inputChannels,
                                outputChannels: outputChannels
                            )
                            .map(String.init)
                            .joined(separator: "+")
                    }
                    print("声道映射：输出 \(outputChannels) 声道 ← 输入 \(ranges.joined(separator: " | "))")
                }
            }
            let target = state.targetGain.load(ordering: .relaxed)
            let succeeded = Self.copyAndScale(
                input: inputData,
                output: outputData,
                currentGain: &currentGain,
                targetGain: target
            )
            if succeeded {
                state.invalidCallbackCount.store(0, ordering: .relaxed)
            } else {
                let failures = state.invalidCallbackCount.load(ordering: .relaxed) + 1
                state.invalidCallbackCount.store(failures, ordering: .relaxed)
                guard failures >= 8 else { return }
                state.callbackFailed.store(true, ordering: .relaxed)
            }
        }
        try require(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDeviceID,
                queue,
                block
            ),
            "创建 IOProc"
        )
        try require(AudioDeviceStart(aggregateDeviceID, ioProcID), "启动聚合设备")

        for process in processes {
            print("目标：\(process.bundleID) pid=\(process.pid) object=\(process.objectID)")
        }
        print("输出：\(outputUID)")
        print("格式：\(tapFormat.debugSummary)")
    }

    func setGain(_ gain: Float) {
        state.targetGain.store(min(max(gain, 0), 1), ordering: .relaxed)
        print("切换增益：\(Int((gain * 100).rounded()))%")
    }

    func validateCallback() throws {
        guard state.callbackStarted.load(ordering: .relaxed) else {
            throw TapProbeError.coreAudio("等待音频回调", -1)
        }
        guard !state.callbackFailed.load(ordering: .relaxed) else {
            throw TapProbeError.incompatibleBuffers
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func copyAndScale(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        currentGain: inout Float,
        targetGain: Float
    ) -> Bool {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outputs {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }

        let inputChannels = ProbeBufferLayout.totalChannels(inputs)
        let outputChannels = ProbeBufferLayout.totalChannels(outputs)
        guard inputChannels > 0, outputChannels > 0 else { return false }

        let frameCount = min(ProbeBufferLayout.frames(inputs), ProbeBufferLayout.frames(outputs))
        guard frameCount > 0 else { return false }

        let gainStep = (targetGain - currentGain) / Float(frameCount)
        for channel in 0..<outputChannels {
            let sourceRange = ProbeBufferLayout.sourceRange(
                outputChannel: channel,
                inputChannels: inputChannels,
                outputChannels: outputChannels
            )
            guard !sourceRange.isEmpty,
                  let destination = ProbeBufferLayout.accessor(outputs, channel: channel),
                  let destinationData = outputs[destination.index].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            var gain = currentGain
            for frame in 0..<frameCount {
                var sum: Float = 0
                var sourceCount = 0
                for source in sourceRange {
                    guard let accessor = ProbeBufferLayout.accessor(inputs, channel: source),
                          let sourceData = inputs[accessor.index].mData?.assumingMemoryBound(to: Float.self) else {
                        continue
                    }
                    sum += sourceData[accessor.offset + frame * accessor.stride]
                    sourceCount += 1
                }
                guard sourceCount > 0 else { continue }
                gain += gainStep
                let value = sourceCount > 1 ? sum / Float(sourceCount) : sum
                destinationData[destination.offset + frame * destination.stride] =
                    min(max(value * gain, -1), 1)
            }
        }
        currentGain = targetGain
        return true
    }
}

private func require(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw TapProbeError.coreAudio(operation, status)
    }
}

private func readProcessList() throws -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try require(
        AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size),
        "读取音频进程数量"
    )
    var values = [AudioObjectID](
        repeating: kAudioObjectUnknown,
        count: Int(size) / MemoryLayout<AudioObjectID>.size
    )
    try require(
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &values),
        "读取音频进程"
    )
    return values
}

private func readScalar<T>(
    object: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<T>.size)
    let pointer = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<T>.size,
        alignment: MemoryLayout<T>.alignment
    )
    defer { pointer.deallocate() }
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
    try require(
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer),
        "读取属性 \(selector.fourCC)"
    )
    return pointer.load(as: T.self)
}

private func readString(
    object: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    try require(
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value),
        "读取字符串属性 \(selector.fourCC)"
    )
    guard let value else { return "" }
    return value.takeUnretainedValue() as String
}

private func findProcesses(bundlePrefix: String) throws -> [ProbeProcess] {
    let candidates: [ProbeProcess] = try readProcessList().compactMap { objectID in
        guard let bundleID = try? readString(
            object: objectID,
            selector: kAudioProcessPropertyBundleID
        ),
        !bundleID.isEmpty,
        bundleID == bundlePrefix || bundleID.hasPrefix(bundlePrefix + "."),
        let rawPID: Int32 = try? readScalar(
            object: objectID,
            selector: kAudioProcessPropertyPID
        ) else {
            return nil
        }
        return ProbeProcess(objectID: objectID, pid: pid_t(rawPID), bundleID: bundleID)
    }

    let hasRunningOutput = candidates.contains { process in
        let running: UInt32? = try? readScalar(
            object: process.objectID,
            selector: kAudioProcessPropertyIsRunningOutput
        )
        return running != 0
    }
    guard !candidates.isEmpty, hasRunningOutput else {
        throw TapProbeError.noMatchingProcess(bundlePrefix)
    }
    return candidates.sorted { $0.objectID < $1.objectID }
}

private extension UInt32 {
    var fourCC: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff)
        ]
        let printable = bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(printable)
    }
}

private extension AudioStreamBasicDescription {
    var debugSummary: String {
        "\(mSampleRate) Hz, channels=\(mChannelsPerFrame), bits=\(mBitsPerChannel), format=\(mFormatID.fourCC), flags=0x\(String(mFormatFlags, radix: 16))"
    }
}

do {
    guard CommandLine.arguments.count >= 2 else { throw TapProbeError.usage }
    let bundlePrefix = CommandLine.arguments[1]
    let requestedGain = Float(CommandLine.arguments.dropFirst(2).first ?? "0.37") ?? 0.37
    let duration = Double(CommandLine.arguments.dropFirst(3).first ?? "12") ?? 12
    let gain = min(max(requestedGain, 0), 1)
    let processes = try findProcesses(bundlePrefix: bundlePrefix)
    let probe = TapProbe(gain: gain)
    try probe.start(processes: processes)
    print("请持续播放目标 App 音频；脚本会在中途切换增益，\(duration) 秒后自动清理。")

    let firstPhase = max(duration / 2, 1)
    RunLoop.current.run(until: Date().addingTimeInterval(firstPhase))
    try probe.validateCallback()
    probe.setGain(gain < 0.7 ? 0.85 : 0.25)
    RunLoop.current.run(until: Date().addingTimeInterval(max(duration - firstPhase, 1)))
    try probe.validateCallback()
    probe.stop()
    print("验证完成：Tap、IOProc 和聚合设备已销毁，目标 App 应恢复原始音量。")
} catch {
    fputs("验证失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
