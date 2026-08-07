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
    case openFailed
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
    case nonSuccessfulResponse
    case alreadyDownloading
}

/// 将 URLSession 下载结果校验并安全移动到服务层指定的临时路径。
final class URLSessionUpdatePackageDownloader: UpdatePackageDownloading, @unchecked Sendable {
    private static let supportedExtensions: Set<String> = ["zip", "dmg", "pkg"]

    private let transport: any UpdateDownloadTransport
    private let fileManager: any UpdateDownloadFileManaging
    private let lock = NSLock()
    private var isDownloading = false

    init(
        transport: any UpdateDownloadTransport = URLSessionUpdateDownloadTransport(),
        fileManager: any UpdateDownloadFileManaging = DefaultUpdateDownloadFileManager()
    ) {
        self.transport = transport
        self.fileManager = fileManager
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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !isDownloading else {
                    lock.unlock()
                    continuation.resume(throwing: URLSessionUpdatePackageDownloaderError.alreadyDownloading)
                    return
                }
                isDownloading = true
                lock.unlock()

                transport.startDownload(
                    from: url,
                    progress: progress,
                    completion: { [weak self] result in
                        guard let self else { return }
                        self.finish(
                            result,
                            destination: destination,
                            continuation: continuation
                        )
                    }
                )
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        transport.cancel()
    }

    private func finish(
        _ result: Result<UpdateDownloadTransportResponse, Error>,
        destination: URL,
        continuation: CheckedContinuation<URL, Error>
    ) {
        defer {
            lock.lock()
            isDownloading = false
            lock.unlock()
        }

        switch result {
        case let .failure(error):
            continuation.resume(throwing: error)
        case let .success(response):
            guard let statusCode = response.statusCode,
                  (200...299).contains(statusCode) else {
                continuation.resume(throwing: URLSessionUpdatePackageDownloaderError.nonSuccessfulResponse)
                return
            }
            do {
                try fileManager.moveItem(at: response.temporaryURL, to: destination)
                continuation.resume(returning: destination)
            } catch {
                // 保留原始文件错误，让上层决定本地化展示方式。
                continuation.resume(throwing: error)
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
    private var progressHandler: (@Sendable (Double) -> Void)?
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
            completion(.failure(URLSessionUpdatePackageDownloaderError.alreadyDownloading))
            return
        }
        activeTask = task
        progressHandler = progress
        self.completion = completion
        lock.unlock()

        task.resume()
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        lock.unlock()
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
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock()
        let handler = activeTask?.taskIdentifier == downloadTask.taskIdentifier ? progressHandler : nil
        lock.unlock()
        handler?(min(max(progress, 0), 1))
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard activeTask?.taskIdentifier == downloadTask.taskIdentifier,
              let completion else {
            lock.unlock()
            return
        }
        activeTask = nil
        progressHandler = nil
        self.completion = nil
        lock.unlock()

        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        completion(.success(UpdateDownloadTransportResponse(statusCode: statusCode, temporaryURL: location)))
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        lock.lock()
        guard activeTask?.taskIdentifier == task.taskIdentifier,
              let completion else {
            lock.unlock()
            return
        }
        activeTask = nil
        progressHandler = nil
        self.completion = nil
        lock.unlock()

        completion(.failure(error))
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
