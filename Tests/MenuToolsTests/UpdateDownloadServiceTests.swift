import Foundation
import Testing
@testable import MenuTools

private enum StubDownloadError: Error, Sendable {
    case failed
}

private enum AdapterStubError: Error, Sendable {
    case readFailed
    case cancelled
}

private actor AdapterTransportControl {
    private var completion: (@Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void)?
    private var progress: (@Sendable (Double) -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func start(
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void
    ) {
        self.progress = progress
        self.completion = completion
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(_ result: Result<UpdateDownloadTransportResponse, Error>) {
        completion?(result)
        completion = nil
    }

    func reportProgress(_ value: Double) {
        progress?(value)
    }
}

private struct ControlledAdapterTransport: UpdateDownloadTransport {
    let control: AdapterTransportControl

    func startDownload(
        from _: URL,
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void
    ) {
        Task {
            await control.start(progress: progress, completion: completion)
        }
    }

    func cancel() {
        Task {
            await control.finish(.failure(AdapterStubError.cancelled))
        }
    }
}

private enum FileMoveStubError: Error, Sendable {
    case moveFailed
}

private final class RecordingFileManager: UpdateDownloadFileManaging, @unchecked Sendable {
    let moveError: FileMoveStubError?
    private(set) var source: URL?
    private(set) var destination: URL?

    init(moveError: FileMoveStubError?) {
        self.moveError = moveError
    }

    func moveItem(at source: URL, to destination: URL) throws {
        self.source = source
        self.destination = destination
        if let moveError { throw moveError }
    }
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

@Test("下载适配器拒绝非成功 HTTP 响应")
func adapterRejectsNonSuccessfulHTTPResponse() async {
    let control = AdapterTransportControl()
    let adapter = URLSessionUpdatePackageDownloader(
        transport: ControlledAdapterTransport(control: control),
        fileManager: DefaultUpdateDownloadFileManager()
    )
    let temporaryURL = URL(fileURLWithPath: "/tmp/source.zip")
    let destination = URL(fileURLWithPath: "/tmp/destination.zip")

    let task = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/source.zip")!,
            to: destination,
            progress: { _ in }
        )
    }
    await control.waitUntilStarted()
    await control.finish(.success(.init(statusCode: 404, temporaryURL: temporaryURL)))

    await #expect(throws: URLSessionUpdatePackageDownloaderError.nonSuccessfulResponse) {
        try await task.value
    }
}

@Test("下载适配器拒绝不支持的扩展名")
func adapterRejectsUnsupportedExtension() async {
    let control = AdapterTransportControl()
    let adapter = URLSessionUpdatePackageDownloader(
        transport: ControlledAdapterTransport(control: control),
        fileManager: DefaultUpdateDownloadFileManager()
    )

    await #expect(throws: URLSessionUpdatePackageDownloaderError.unsupportedFileType) {
        try await adapter.download(
            from: URL(string: "https://example.com/source.tar.gz")!,
            to: URL(fileURLWithPath: "/tmp/destination.tar.gz"),
            progress: { _ in }
        )
    }
}

@Test("下载适配器保留下载源的文件错误")
func adapterPreservesReadError() async {
    let control = AdapterTransportControl()
    let adapter = URLSessionUpdatePackageDownloader(
        transport: ControlledAdapterTransport(control: control),
        fileManager: RecordingFileManager(moveError: nil)
    )
    let task = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/source.zip")!,
            to: URL(fileURLWithPath: "/tmp/destination.zip"),
            progress: { _ in }
        )
    }
    await control.waitUntilStarted()
    await control.finish(.failure(AdapterStubError.readFailed))

    await #expect(throws: AdapterStubError.readFailed) {
        try await task.value
    }
}

@Test("下载适配器在移动失败时不返回完成路径")
func adapterRejectsMoveError() async {
    let control = AdapterTransportControl()
    let adapter = URLSessionUpdatePackageDownloader(
        transport: ControlledAdapterTransport(control: control),
        fileManager: RecordingFileManager(moveError: .moveFailed)
    )
    let task = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/source.zip")!,
            to: URL(fileURLWithPath: "/tmp/destination.zip"),
            progress: { _ in }
        )
    }
    await control.waitUntilStarted()
    await control.finish(.success(.init(
        statusCode: 200,
        temporaryURL: URL(fileURLWithPath: "/tmp/source.zip")
    )))

    await #expect(throws: FileMoveStubError.moveFailed) {
        try await task.value
    }
}

@Test("下载适配器转发进度并在成功后返回目标路径")
func adapterReportsProgressAndFinalizesDestination() async throws {
    let control = AdapterTransportControl()
    let fileManager = RecordingFileManager(moveError: nil)
    let adapter = URLSessionUpdatePackageDownloader(
        transport: ControlledAdapterTransport(control: control),
        fileManager: fileManager
    )
    let progress = ProgressRecorder()
    let destination = URL(fileURLWithPath: "/tmp/destination.zip")
    let task = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/source.zip")!,
            to: destination,
            progress: { value in
                Task { await progress.record(value) }
            }
        )
    }
    await control.waitUntilStarted()
    await control.reportProgress(0.4)
    await control.reportProgress(1.0)
    await control.finish(.success(.init(
        statusCode: 200,
        temporaryURL: URL(fileURLWithPath: "/tmp/source.zip")
    )))

    let result = try await task.value
    #expect(result == destination)
    #expect(await progress.values == [0.4, 1.0])
    #expect(fileManager.source == URL(fileURLWithPath: "/tmp/source.zip"))
    #expect(fileManager.destination == destination)
}

@Test("取消下载会取消传输并抛出取消错误")
func adapterSupportsCancellation() async {
    let control = AdapterTransportControl()
    let adapter = URLSessionUpdatePackageDownloader(
        transport: ControlledAdapterTransport(control: control),
        fileManager: DefaultUpdateDownloadFileManager()
    )
    let task = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/source.zip")!,
            to: URL(fileURLWithPath: "/tmp/destination.zip"),
            progress: { _ in }
        )
    }
    await control.waitUntilStarted()
    task.cancel()

    await #expect(throws: AdapterStubError.cancelled) {
        try await task.value
    }
}

private actor ProgressRecorder {
    private(set) var values: [Double] = []

    func record(_ value: Double) {
        values.append(value)
    }
}
