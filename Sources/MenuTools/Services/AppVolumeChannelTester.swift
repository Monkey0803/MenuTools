import AVFoundation
import Foundation

/// 声道测试音：一段带淡入淡出的正弦波。
///
/// 走系统输出播放，用来验证音箱接线与系统左右声道；单个 App 的左右平衡请在播放该 App 时调整。
enum AppVolumeTestTone {
    static let defaultFrequency = 440.0
    static let defaultDuration = 3.0
    static let defaultSampleRate = 48_000.0
    /// 测试音幅度：够听清又不刺耳，且限制上限避免误操作伤耳。
    static let defaultAmplitude = 0.25
    static let maximumAmplitude = 0.5
    static let fadeDuration = 0.03

    static func normalizedAmplitude(_ amplitude: Double) -> Double {
        let value = amplitude.isFinite ? amplitude : defaultAmplitude
        return min(max(value, 0.01), maximumAmplitude)
    }

    static func samples(
        frequency: Double = defaultFrequency,
        duration: Double = defaultDuration,
        sampleRate: Double = defaultSampleRate,
        amplitude: Double = defaultAmplitude
    ) -> [Float] {
        let safeSampleRate = sampleRate > 0 ? sampleRate : defaultSampleRate
        let safeDuration = duration > 0 ? duration : defaultDuration
        let count = Int((safeDuration * safeSampleRate).rounded())
        guard count > 0 else { return [] }
        let peak = normalizedAmplitude(amplitude)
        // 频率不高于采样率的 45%，避免混叠
        let safeFrequency = min(max(frequency.isFinite ? frequency : defaultFrequency, 20), safeSampleRate * 0.45)
        let fadeSamples = max(1, Int((fadeDuration * safeSampleRate).rounded()))

        return (0 ..< count).map { index in
            let phase = 2 * Double.pi * safeFrequency * Double(index) / safeSampleRate
            var value = sin(phase) * peak
            // 首尾各淡入淡出一段，避免爆音
            if index < fadeSamples {
                value *= Double(index) / Double(fadeSamples)
            } else if index >= count - fadeSamples {
                value *= Double(count - index) / Double(fadeSamples)
            }
            return Float(value)
        }
    }
}

/// 左右声道测试音的播放器。
@MainActor
@Observable
final class AppVolumeChannelTester {
    enum Channel: String, CaseIterable, Sendable {
        case left
        case right
        case both

        var titleKey: String { "volume.channelTest.\(rawValue)" }

        /// AVAudioPlayerNode 的声像：-1 全左、0 居中、+1 全右。
        var pan: Float {
            switch self {
            case .left: -1
            case .right: 1
            case .both: 0
            }
        }
    }

    static let shared = AppVolumeChannelTester()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var stopTask: Task<Void, Never>?
    private var isEngineConfigured = false

    private(set) var isPlaying = false
    private(set) var playingChannel: Channel?

    func play(_ channel: Channel, duration: TimeInterval = AppVolumeTestTone.defaultDuration) {
        stop()
        let sampleRate = AppVolumeTestTone.defaultSampleRate
        let samples = AppVolumeTestTone.samples(duration: duration, sampleRate: sampleRate)
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channelData = buffer.floatChannelData else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            channelData[0][index] = samples[index]
        }

        do {
            if !isEngineConfigured {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                isEngineConfigured = true
            }
            player.pan = channel.pan
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            isPlaying = false
            playingChannel = nil
            return
        }

        isPlaying = true
        playingChannel = channel
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        if player.isPlaying {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        isPlaying = false
        playingChannel = nil
    }
}