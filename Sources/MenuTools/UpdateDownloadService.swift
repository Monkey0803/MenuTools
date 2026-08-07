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
