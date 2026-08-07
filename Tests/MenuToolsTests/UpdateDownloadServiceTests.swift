import Foundation
import Testing
@testable import MenuTools

private enum StubDownloadError: Error {
    case failed
}

private final class StubDownloader: UpdatePackageDownloading, @unchecked Sendable {
    var result: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/MenuTools.zip"))
    var requestedURL: URL?
    var destinationURL: URL?
    var reportedProgress: [Double] = []
    var cancelCallCount = 0

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        requestedURL = url
        destinationURL = destination
        progress(0.5)
        reportedProgress.append(0.5)
        switch result {
        case .success:
            return destination
        case .failure:
            return try result.get()
        }
    }

    func cancel() {
        cancelCallCount += 1
    }
}

private final class StubOpener: UpdatePackageOpening, @unchecked Sendable {
    var openedURL: URL?
    var result = true

    func open(_ url: URL) -> Bool {
        openedURL = url
        return result
    }
}

private func update(url: String?) -> UpdateInfo {
    UpdateInfo(version: "1.0.2", notes: nil, url: url)
}

private func waitForDownloadTask() async {
    try? await Task.sleep(for: .milliseconds(20))
}

@Test("服务初始为空闲并接受一次下载")
@MainActor
func serviceStartsDownloadingFromIdle() {
    let downloader = StubDownloader()
    let service = UpdateDownloadService(downloader: downloader, opener: StubOpener())

    #expect(service.state == .idle)
    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    #expect(service.state == .downloading(progress: 0))
}

@Test("下载进行中拒绝重复启动并保留当前状态")
@MainActor
func serviceRejectsDuplicateStart() {
    let downloader = StubDownloader()
    let service = UpdateDownloadService(downloader: downloader, opener: StubOpener())
    let first = update(url: "https://example.com/first.zip")
    let second = update(url: "https://example.com/second.zip")

    #expect(service.start(update: first))
    #expect(!service.start(update: second))
    #expect(service.state == .downloading(progress: 0))
}

@Test("只接受 zip、dmg 和 pkg 安装包")
@MainActor
func serviceAcceptsSupportedPackageExtensions() {
    for extensionName in ["zip", "dmg", "pkg"] {
        let service = UpdateDownloadService(
            downloader: StubDownloader(),
            opener: StubOpener()
        )

        #expect(service.start(update: update(url: "https://example.com/MenuTools.\(extensionName)")))
        #expect(service.state == .downloading(progress: 0))
    }

    let service = UpdateDownloadService(downloader: StubDownloader(), opener: StubOpener())
    #expect(!service.start(update: update(url: "https://example.com/MenuTools.tar.gz")))
    #expect(service.state == .failed(.unsupportedFileType))
}

@Test("无效下载地址会进入失败状态")
@MainActor
func serviceRejectsInvalidURL() {
    let service = UpdateDownloadService(downloader: StubDownloader(), opener: StubOpener())

    #expect(!service.start(update: update(url: "%%%")))
    #expect(service.state == .failed(.invalidURL))
}

@Test("取消下载会通知下载器并进入取消失败状态")
@MainActor
func serviceCancelsDownload() async {
    let downloader = StubDownloader()
    let service = UpdateDownloadService(downloader: downloader, opener: StubOpener())

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    service.cancel()
    await Task.yield()

    #expect(downloader.cancelCallCount == 1)
    #expect(service.state == .failed(.cancelled))
}

@Test("下载成功后进入完成状态并保存到临时目录")
@MainActor
func serviceTransitionsToCompletedAfterDownload() async {
    let downloader = StubDownloader()
    let service = UpdateDownloadService(downloader: downloader, opener: StubOpener())

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await waitForDownloadTask()

    guard case let .completed(url) = service.state else {
        Issue.record("下载成功后应进入 completed 状态，实际为 \(service.state)")
        return
    }
    #expect(url.pathExtension == "zip")
    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(downloader.destinationURL == url)
}

@Test("下载器失败会进入下载失败状态")
@MainActor
func serviceTransitionsToFailedAfterDownloadError() async {
    let downloader = StubDownloader()
    downloader.result = .failure(StubDownloadError.failed)
    let service = UpdateDownloadService(downloader: downloader, opener: StubOpener())

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await waitForDownloadTask()

    #expect(service.state == .failed(.downloadFailed))
}

@Test("完成后可通过注入的打开器打开安装包")
@MainActor
func serviceOpensCompletedPackage() async {
    let opener = StubOpener()
    let service = UpdateDownloadService(downloader: StubDownloader(), opener: opener)

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await waitForDownloadTask()

    #expect(service.openCompletedPackage())
    #expect(opener.openedURL != nil)
}
