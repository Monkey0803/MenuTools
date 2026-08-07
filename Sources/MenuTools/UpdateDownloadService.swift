import AppKit
import Foundation

/// 更新安装包的下载状态。
enum UpdateDownloadState: Equatable, Sendable {
    case idle
    case downloading(progress: Double)
    case completed(URL)
    case failed(UpdateDownloadError)
}

/// 更新安装包下载和打开过程中可向界面暴露的错误。
enum UpdateDownloadError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedFileType
    case alreadyDownloading
    case cancelled
    case downloadFailed
    case downloadFailedWithReason(UpdateDownloadFailureReason)
    case openFailed
}

/// 可供界面本地化的下载失败类别；不携带路径、响应体或底层错误文本。
enum UpdateDownloadFailureReason: Error, Equatable, Sendable {
    case invalidResponse
    case transport
    case fileRead
    case fileMove
    case cancelled
}

/// 下载边界；实现负责把文件放到传入的目标路径并报告进度。
protocol UpdatePackageDownloading: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    func cancel()
}

/// 安装包打开边界，避免服务层直接依赖 AppKit。
@MainActor
protocol UpdatePackageOpening: Sendable {
    func open(_ url: URL) -> Bool
}

/// URLSession 下载传输层返回的临时文件和 HTTP 状态。
struct UpdateDownloadTransportResponse: Sendable {
    let statusCode: Int?
    let temporaryURL: URL
}

/// URLSession 下载传输边界，便于在不访问网络的情况下验证适配器。
protocol UpdateDownloadTransport: Sendable {
    func startDownload(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void
    )

    func cancel()
}

/// 临时文件移动边界，确保下载适配器不会直接依赖文件系统实现。
protocol UpdateDownloadFileManaging: Sendable {
    func moveItem(at source: URL, to destination: URL) throws
}

struct DefaultUpdateDownloadFileManager: UpdateDownloadFileManaging {
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

enum URLSessionUpdatePackageDownloaderError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedFileType
    case alreadyDownloading
}

/// 把 URLSession delegate 的事件规整为一次性、可测试的下载结果。
final class URLSessionDownloadLifecycle: @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void
    private let completion: @Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void
    private let lock = NSLock()
    private var statusCode: Int?
    private var isFinished = false

    init(
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void
    ) {
        progressHandler = progress
        self.completion = completion
    }

    func receiveResponse(statusCode: Int?) {
        lock.lock()
        if !isFinished { self.statusCode = statusCode }
        lock.unlock()
    }

    func didWrite(totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let shouldReport = !isFinished
        lock.unlock()
        guard shouldReport else { return }
        progressHandler(min(max(
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite),
            0
        ), 1))
    }

    func didFinishDownloading(to location: URL) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let statusCode = self.statusCode
        lock.unlock()

        completion(.success(UpdateDownloadTransportResponse(
            statusCode: statusCode,
            temporaryURL: location
        )))
    }

    func didComplete(withError error: Error?) {
        guard error != nil else { return }
        finish(with: UpdateDownloadFailureReason.transport)
    }

    func cancel() {
        finish(with: UpdateDownloadFailureReason.cancelled)
    }

    private func finish(with error: UpdateDownloadFailureReason) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()
        completion(.failure(error))
    }
}

/// 将 URLSession 下载结果校验并安全移动到服务层指定的临时路径。
final class URLSessionUpdatePackageDownloader: UpdatePackageDownloading, @unchecked Sendable {
    private static let supportedExtensions: Set<String> = ["zip", "dmg", "pkg"]

    private struct ActiveDownload {
        let id: Int
        let transport: any UpdateDownloadTransport
        let continuation: CheckedContinuation<URL, Error>
        let destination: URL
    }

    private let transportFactory: @Sendable () -> any UpdateDownloadTransport
    private let fileManager: any UpdateDownloadFileManaging
    private let lock = NSLock()
    private var nextDownloadID = 0
    private var activeDownload: ActiveDownload?

    init(
        transportFactory: @escaping @Sendable () -> any UpdateDownloadTransport = {
            URLSessionUpdateDownloadTransport()
        },
        fileManager: any UpdateDownloadFileManaging = DefaultUpdateDownloadFileManager()
    ) {
        self.transportFactory = transportFactory
        self.fileManager = fileManager
    }

    convenience init(
        transport: any UpdateDownloadTransport,
        fileManager: any UpdateDownloadFileManaging = DefaultUpdateDownloadFileManager()
    ) {
        self.init(transportFactory: { transport }, fileManager: fileManager)
    }

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw URLSessionUpdatePackageDownloaderError.invalidURL
        }
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw URLSessionUpdatePackageDownloaderError.unsupportedFileType
        }
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: UpdateDownloadFailureReason.cancelled)
                    return
                }
                guard activeDownload == nil else {
                    lock.unlock()
                    continuation.resume(throwing: URLSessionUpdatePackageDownloaderError.alreadyDownloading)
                    return
                }
                nextDownloadID += 1
                let id = nextDownloadID
                let transport = transportFactory()
                activeDownload = ActiveDownload(
                    id: id,
                    transport: transport,
                    continuation: continuation,
                    destination: destination
                )
                lock.unlock()

                transport.startDownload(
                    from: url,
                    progress: progress,
                    completion: { [weak self] result in
                        self?.finish(result, for: id)
                    }
                )
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let activeDownload: ActiveDownload? = self.activeDownload
        self.activeDownload = nil
        lock.unlock()

        guard let activeDownload else { return }
        activeDownload.transport.cancel()
        activeDownload.continuation.resume(throwing: UpdateDownloadFailureReason.cancelled)
    }

    private func finish(
        _ result: Result<UpdateDownloadTransportResponse, Error>,
        for id: Int
    ) {
        lock.lock()
        guard let activeDownload, activeDownload.id == id else {
            lock.unlock()
            return
        }
        self.activeDownload = nil
        lock.unlock()

        switch result {
        case let .failure(error):
            let reason = error as? UpdateDownloadFailureReason ?? .transport
            activeDownload.continuation.resume(throwing: reason)
        case let .success(response):
            guard let statusCode = response.statusCode,
                  (200...299).contains(statusCode) else {
                activeDownload.continuation.resume(throwing: UpdateDownloadFailureReason.invalidResponse)
                return
            }
            do {
                try fileManager.moveItem(
                    at: response.temporaryURL,
                    to: activeDownload.destination
                )
                activeDownload.continuation.resume(returning: activeDownload.destination)
            } catch {
                activeDownload.continuation.resume(throwing: UpdateDownloadFailureReason.fileMove)
            }
        }
    }
}

/// 使用 URLSessionDownloadDelegate 提供下载进度和临时文件路径。
private final class URLSessionUpdateDownloadTransport: NSObject, UpdateDownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    private lazy var session: URLSession = URLSession(
        configuration: .ephemeral,
        delegate: self,
        delegateQueue: nil
    )
    private let lock = NSLock()
    private var activeTask: URLSessionDownloadTask?
    private var lifecycle: URLSessionDownloadLifecycle?
    private var completion: (@Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void)?

    func startDownload(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void
    ) {
        let task = session.downloadTask(with: url)

        lock.lock()
        guard activeTask == nil else {
            lock.unlock()
            completion(.failure(UpdateDownloadFailureReason.transport))
            return
        }
        let lifecycle = URLSessionDownloadLifecycle(
            progress: progress,
            completion: { [weak self] result in
                self?.finish(taskID: task.taskIdentifier, result: result)
            }
        )
        activeTask = task
        self.lifecycle = lifecycle
        self.completion = completion
        lock.unlock()

        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        let lifecycle: URLSessionDownloadLifecycle? = self.lifecycle
        lock.unlock()
        lifecycle?.cancel()
        task?.cancel()
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let lifecycle = activeTask?.taskIdentifier == downloadTask.taskIdentifier ? self.lifecycle : nil
        lock.unlock()
        lifecycle?.didWrite(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard activeTask?.taskIdentifier == downloadTask.taskIdentifier,
              let lifecycle else {
            lock.unlock()
            return
        }
        lock.unlock()

        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        lifecycle.receiveResponse(statusCode: statusCode)
        lifecycle.didFinishDownloading(to: location)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard activeTask?.taskIdentifier == task.taskIdentifier,
              let lifecycle else {
            lock.unlock()
            return
        }
        lock.unlock()

        lifecycle.didComplete(withError: error)
    }

    private func finish(
        taskID: Int,
        result: Result<UpdateDownloadTransportResponse, Error>
    ) {
        lock.lock()
        guard activeTask?.taskIdentifier == taskID,
              let completion else {
            lock.unlock()
            return
        }
        activeTask = nil
        lifecycle = nil
        self.completion = nil
        lock.unlock()

        completion(result)
    }
}

/// 在主 actor 上调用系统默认程序打开已完成的安装包。
@MainActor
struct NSWorkspaceUpdatePackageOpener: UpdatePackageOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// 管理更新安装包的校验、下载状态和取消操作。
@MainActor
final class UpdateDownloadService {
    private static let supportedExtensions: Set<String> = ["zip", "dmg", "pkg"]

    private let downloader: any UpdatePackageDownloading
    private let opener: any UpdatePackageOpening
    private let temporaryDirectory = FileManager.default.temporaryDirectory
    private var downloadTask: Task<Void, Never>?
    private var nextGeneration = 0
    private var activeGeneration: Int?
    private var activeDestination: URL?

    private(set) var state: UpdateDownloadState = .idle

    init(
        downloader: any UpdatePackageDownloading,
        opener: any UpdatePackageOpening
    ) {
        self.downloader = downloader
        self.opener = opener
    }

    /// 校验更新地址并开始下载；已有下载任务时不改变当前状态。
    @discardableResult
    func start(update: UpdateInfo) -> Bool {
        guard downloadTask == nil else { return false }

        guard let url = validatedURL(from: update.url) else {
            state = .failed(.invalidURL)
            return false
        }

        let fileExtension = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            state = .failed(.unsupportedFileType)
            return false
        }

        let destination = temporaryDirectory.appendingPathComponent(
            "MenuTools-\(UUID().uuidString).\(fileExtension)"
        )
        nextGeneration += 1
        let generation = nextGeneration
        activeGeneration = generation
        activeDestination = destination
        state = .downloading(progress: 0)

        let downloader = self.downloader
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeGeneration == generation {
                    self.activeGeneration = nil
                    self.activeDestination = nil
                    self.downloadTask = nil
                }
            }

            do {
                guard self.activeGeneration == generation, !Task.isCancelled else { return }
                let downloadedURL = try await downloader.download(
                    from: url,
                    to: destination,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.activeGeneration == generation,
                                  case .downloading = self.state else { return }
                            self.state = .downloading(progress: min(max(progress, 0), 1))
                        }
                    }
                )
                guard self.activeGeneration == generation,
                      !Task.isCancelled else { return }
                guard self.isOwnedDestination(downloadedURL, expected: destination) else {
                    self.state = .failed(.downloadFailed)
                    return
                }
                self.state = .completed(destination)
            } catch let reason as UpdateDownloadFailureReason {
                guard self.activeGeneration == generation, !Task.isCancelled else { return }
                self.state = .failed(.downloadFailedWithReason(reason))
            } catch {
                guard self.activeGeneration == generation, !Task.isCancelled else { return }
                self.state = .failed(.downloadFailed)
            }
        }
        return true
    }

    /// 取消当前下载，并保留可供界面展示的取消状态。
    @discardableResult
    func cancel() -> Bool {
        guard activeGeneration != nil, case .downloading = state else { return false }

        downloadTask?.cancel()
        downloader.cancel()
        activeGeneration = nil
        activeDestination = nil
        downloadTask = nil
        state = .failed(.cancelled)
        return true
    }

    /// 打开已经下载完成的安装包；不会执行下载内容或替换当前应用。
    @discardableResult
    func openCompletedPackage() -> Bool {
        guard case let .completed(url) = state else { return false }
        guard opener.open(url) else {
            state = .failed(.openFailed)
            return false
        }
        return true
    }

    private func validatedURL(from rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private func isOwnedDestination(_ url: URL, expected: URL) -> Bool {
        guard url.isFileURL,
              url.standardizedFileURL == expected.standardizedFileURL,
              let activeDestination,
              activeDestination.standardizedFileURL == expected.standardizedFileURL else {
            return false
        }

        let temporaryPath = temporaryDirectory.standardizedFileURL.path
        return expected.standardizedFileURL.path.hasPrefix(temporaryPath + "/")
    }
}
