import CoreGraphics
import Vision

/// 组合 Vision OCR 和二维码识别结果。二维码内容如果已经出现在 OCR 文本中，
/// 只保留一份，避免复制后在聊天软件里出现重复链接。
enum ScreenshotOCRResultComposer {
    static func compose(textLines: [String], barcodePayloads: [String]) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        for line in textLines {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            lines.append(value)
        }

        let textBlock = lines.joined(separator: "\n")
        for payload in barcodePayloads {
            let value = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !textBlock.contains(value),
                  seen.insert(value).inserted else { continue }
            lines.append(value)
        }
        return lines.joined(separator: "\n")
    }
}

enum ScreenshotOCRError: LocalizedError {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText:
            return L("screenshot.ocr.noText")
        }
    }
}

/// 进程级 Vision 串行闸门。
///
/// Vision 在并发压力下可能整批返回空结果（剪贴板图片识别、标注器 OCR、区域 OCR 同时
/// 发起请求时最容易触发），因此这些入口共用同一把闸；闸门是进程级的，不是每个服务
/// 实例一把，否则跨功能并发依然会互相干扰。
actor VisionRecognitionGate {
    static let shared = VisionRecognitionGate()

    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isAvailable {
            isAvailable = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isAvailable = true
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 截图后的本地 OCR/二维码识别，不上传图片，也不依赖网络服务。
enum ScreenshotOCRService {
    /// 占用进程级闸门后再执行识别；所有后台/交互入口都应走这个版本。
    static func recognizeExclusively(_ image: CGImage) async throws -> String {
        await VisionRecognitionGate.shared.acquire()
        do {
            let result = try recognize(image)
            await VisionRecognitionGate.shared.release()
            return result
        } catch {
            await VisionRecognitionGate.shared.release()
            throw error
        }
    }

    static func recognize(_ image: CGImage) throws -> String {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

        let barcodeRequest = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([textRequest, barcodeRequest])

        let textLines = (textRequest.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        let barcodePayloads = (barcodeRequest.results ?? []).compactMap { $0.payloadStringValue }
        let result = ScreenshotOCRResultComposer.compose(
            textLines: textLines,
            barcodePayloads: barcodePayloads
        )
        guard !result.isEmpty else { throw ScreenshotOCRError.noText }
        return result
    }
}
