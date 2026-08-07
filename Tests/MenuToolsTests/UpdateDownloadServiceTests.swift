import Foundation
import Testing
@testable import MenuTools

private enum StubDownloadError: Error, Sendable {
    case failed
}

private enum ControlledDownloadResult: Sendable {
    case success(URL?)
    case failure
}

private actor DownloadControl {
    private var destinations: [URL] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomes: [Int: ControlledDownloadResult] = [:]
    private var outcomeWaiters: [Int: CheckedContinuation<ControlledDownloadResult, Never>] = [:]
    private var returnedCount = 0
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationCount = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func register(destination: URL) -> Int {
        destinations.append(destination)
        let operation = destinations.count - 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return operation
    }

    func waitUntilStarted(_ count: Int) async {
        guard destinations.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func destination(at index: Int) -> URL {
        destinations[index]
    }

    func complete(_ result: ControlledDownloadResult, for operation: Int) {
        if let continuation = outcomeWaiters.removeValue(forKey: operation) {
            continuation.resume(returning: result)
        } else {
            outcomes[operation] = result
        }
    }

    func result(for operation: Int) async -> ControlledDownloadResult {
        if let result = outcomes.removeValue(forKey: operation) {
            return result
        }
        return await withCheckedContinuation { continuation in
            outcomeWaiters[operation] = continuation
        }
    }

    func markReturned() {
        returnedCount += 1
        let waiters = returnWaiters
        returnWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilReturned(_ count: Int) async {
        guard returnedCount < count else { return }
        await withCheckedContinuation { continuation in
            returnWaiters.append(continuation)
        }
    }

    func requestCancellation() {
        cancellationCount += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilCancelled() async {
        guard cancellationCount == 0 else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }
}

private struct ControlledDownloader: UpdatePackageDownloading {
    let control: DownloadControl

    func download(
        from _: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let operation = await control.register(destination: destination)
        let result = await control.result(for: operation)
        await control.markReturned()

        switch result {
        case let .success(returnedURL):
            return returnedURL ?? destination
        case .failure:
            throw StubDownloadError.failed
        }
    }

    func cancel() {
        Task {
            await control.requestCancellation()
        }
    }
}

@MainActor
private final class StubOpener: UpdatePackageOpening {
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

@MainActor
private func waitForState(
    _ service: UpdateDownloadService,
    _ expected: UpdateDownloadState
) async {
    for _ in 0..<100 {
        if service.state == expected { return }
        await Task.yield()
    }
    #expect(service.state == expected)
}

@Test("服务初始为空闲并接受一次下载")
@MainActor
func serviceStartsDownloadingFromIdle() async {
    let control = DownloadControl()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: StubOpener()
    )

    #expect(service.state == .idle)
    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    #expect(service.state == .downloading(progress: 0))

    service.cancel()
    await control.waitUntilCancelled()
}

@Test("下载进行中拒绝重复启动并保留当前状态")
@MainActor
func serviceRejectsDuplicateStart() async {
    let control = DownloadControl()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: StubOpener()
    )
    let first = update(url: "https://example.com/first.zip")
    let second = update(url: "https://example.com/second.zip")

    #expect(service.start(update: first))
    #expect(!service.start(update: second))
    #expect(service.state == .downloading(progress: 0))

    service.cancel()
    await control.waitUntilCancelled()
}

@Test("只接受 zip、dmg 和 pkg 安装包")
@MainActor
func serviceAcceptsSupportedPackageExtensions() async {
    for extensionName in ["zip", "dmg", "pkg"] {
        let control = DownloadControl()
        let service = UpdateDownloadService(
            downloader: ControlledDownloader(control: control),
            opener: StubOpener()
        )

        #expect(service.start(update: update(url: "https://example.com/MenuTools.\(extensionName)")))
        #expect(service.state == .downloading(progress: 0))
        service.cancel()
        await control.waitUntilCancelled()
    }

    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: DownloadControl()),
        opener: StubOpener()
    )
    #expect(!service.start(update: update(url: "https://example.com/MenuTools.tar.gz")))
    #expect(service.state == .failed(.unsupportedFileType))
}

@Test("无效下载地址会进入失败状态")
@MainActor
func serviceRejectsInvalidURL() {
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: DownloadControl()),
        opener: StubOpener()
    )

    #expect(!service.start(update: update(url: "%%%")))
    #expect(service.state == .failed(.invalidURL))
}

@Test("取消下载会通知下载器并立即允许下一代下载")
@MainActor
func serviceCancelsDownload() async {
    let control = DownloadControl()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: StubOpener()
    )

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await control.waitUntilStarted(1)
    #expect(service.cancel())
    await control.waitUntilCancelled()

    #expect(service.state == .failed(.cancelled))
    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    service.cancel()
    await control.waitUntilCancelled()
}

@Test("取消后的迟到结果不会覆盖新一代下载")
@MainActor
func serviceIgnoresLateCompletionFromCancelledGeneration() async {
    let control = DownloadControl()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: StubOpener()
    )

    #expect(service.start(update: update(url: "https://example.com/old.zip")))
    await control.waitUntilStarted(1)
    let oldDestination = await control.destination(at: 0)
    service.cancel()
    await control.waitUntilCancelled()

    #expect(service.start(update: update(url: "https://example.com/new.zip")))
    await control.waitUntilStarted(2)
    let newDestination = await control.destination(at: 1)

    await control.complete(.success(oldDestination), for: 0)
    await control.waitUntilReturned(1)
    await Task.yield()
    #expect(service.state == .downloading(progress: 0))

    await control.complete(.success(newDestination), for: 1)
    await control.waitUntilReturned(2)
    await waitForState(service, .completed(newDestination))

    #expect(service.state == .completed(newDestination))
}

@Test("下载成功后只完成服务创建的临时目标")
@MainActor
func serviceRejectsArbitraryCompletionURL() async {
    let control = DownloadControl()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: StubOpener()
    )

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await control.waitUntilStarted(1)
    let destination = await control.destination(at: 0)
    await control.complete(.success(URL(fileURLWithPath: "/tmp/arbitrary.zip")), for: 0)
    await control.waitUntilReturned(1)
    await waitForState(service, .failed(.downloadFailed))

    #expect(service.state == .failed(.downloadFailed))
    #expect(!service.openCompletedPackage())
    #expect(destination.path.hasPrefix(FileManager.default.temporaryDirectory.path))
}

@Test("下载器失败会进入下载失败状态")
@MainActor
func serviceTransitionsToFailedAfterDownloadError() async {
    let control = DownloadControl()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: StubOpener()
    )

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await control.waitUntilStarted(1)
    await control.complete(.failure, for: 0)
    await control.waitUntilReturned(1)
    await waitForState(service, .failed(.downloadFailed))

    #expect(service.state == .failed(.downloadFailed))
}

@Test("完成后可通过主 actor 打开的注入打开器打开临时安装包")
@MainActor
func serviceOpensCompletedPackage() async {
    let control = DownloadControl()
    let opener = StubOpener()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: opener
    )

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await control.waitUntilStarted(1)
    let destination = await control.destination(at: 0)
    await control.complete(.success(nil), for: 0)
    await control.waitUntilReturned(1)
    await waitForState(service, .completed(destination))

    #expect(service.openCompletedPackage())
    #expect(opener.openedURL == destination)
}
