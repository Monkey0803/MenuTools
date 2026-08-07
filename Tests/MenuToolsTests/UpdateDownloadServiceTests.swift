import Foundation
import Testing
@testable import MenuTools

private enum StubDownloadError: Error, Sendable {
    case failed
}

private actor AdapterTransportControl {
    private var completion: (@Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void)?
    private var progress: (@Sendable (Double) -> Void)?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var didDeliverCompletion = false
    private var startCount = 0

    func start(
        progress: @escaping @Sendable (Double) -> Void,
        completion: @escaping @Sendable (Result<UpdateDownloadTransportResponse, Error>) -> Void
    ) {
        self.progress = progress
        self.completion = completion
        didDeliverCompletion = false
        startCount += 1
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

    var startedCount: Int {
        startCount
    }

    func finish(_ result: Result<UpdateDownloadTransportResponse, Error>) {
        completion?(result)
        didDeliverCompletion = true
        let waiters = completionWaiters
        completionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func reportProgress(_ value: Double) {
        progress?(value)
    }

    func waitUntilCompletionDelivered() async {
        guard !didDeliverCompletion else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
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
            await control.finish(.failure(UpdateDownloadFailureReason.cancelled))
        }
    }
}

private final class AdapterTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [ControlledAdapterTransport]

    init(controls: [AdapterTransportControl]) {
        transports = controls.map(ControlledAdapterTransport.init(control:))
    }

    func makeTransport() -> any UpdateDownloadTransport {
        lock.lock()
        defer { lock.unlock() }
        return transports.removeFirst()
    }
}

private final class DownloadStartGateFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [DownloadStartGate]

    init(gates: [DownloadStartGate]) {
        self.gates = gates
    }

    func makeGate() -> DownloadStartGate {
        lock.lock()
        defer { lock.unlock() }
        return gates.removeFirst()
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

    var startedCount: Int {
        destinations.count
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

@Test("取消尚未开始的下载不会启动下载器")
@MainActor
func serviceCancellationPreventsDeferredDownloadStart() async {
    let control = DownloadControl()
    let service = UpdateDownloadService(
        downloader: ControlledDownloader(control: control),
        opener: StubOpener()
    )

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    #expect(service.cancel())
    await control.waitUntilCancelled()

    #expect(service.start(update: update(url: "https://example.com/retry.zip")))
    await control.waitUntilStarted(1)
    #expect(await control.startedCount == 1)
    #expect(service.state == .downloading(progress: 0))

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

@Test("服务保留安全的下载失败类别")
@MainActor
func servicePreservesTypedDownloadFailureReason() async {
    let control = AdapterTransportControl()
    let service = UpdateDownloadService(
        downloader: URLSessionUpdatePackageDownloader(
            transport: ControlledAdapterTransport(control: control),
            fileManager: DefaultUpdateDownloadFileManager()
        ),
        opener: StubOpener()
    )

    #expect(service.start(update: update(url: "https://example.com/MenuTools.zip")))
    await control.waitUntilStarted()
    await control.finish(.success(.init(
        statusCode: 503,
        temporaryURL: URL(fileURLWithPath: "/tmp/response.zip")
    )))
    await waitForState(
        service,
        .failed(.downloadFailedWithReason(.invalidResponse))
    )

    #expect(service.state == .failed(.downloadFailedWithReason(.invalidResponse)))
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

    await #expect(throws: UpdateDownloadFailureReason.invalidResponse) {
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
    await control.finish(.failure(UpdateDownloadFailureReason.fileRead))

    await #expect(throws: UpdateDownloadFailureReason.fileRead) {
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

    await #expect(throws: UpdateDownloadFailureReason.fileMove) {
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
                progress.record(value)
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
    #expect(await progress.waitForValues(2) == [0.4, 1.0])
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

    await #expect(throws: UpdateDownloadFailureReason.cancelled) {
        try await task.value
    }
}

@Test("旧传输清理期间新下载使用独立传输且忽略旧回调")
func adapterAllowsRetryBeforeOldTransportFinishes() async throws {
    let oldControl = AdapterTransportControl()
    let newControl = AdapterTransportControl()
    let factory = AdapterTransportFactory(controls: [oldControl, newControl])
    let adapter = URLSessionUpdatePackageDownloader(
        transportFactory: { factory.makeTransport() },
        fileManager: RecordingFileManager(moveError: nil)
    )
    let oldDestination = URL(fileURLWithPath: "/tmp/old.zip")
    let newDestination = URL(fileURLWithPath: "/tmp/new.zip")

    let oldTask = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/old.zip")!,
            to: oldDestination,
            progress: { _ in }
        )
    }
    await oldControl.waitUntilStarted()
    adapter.cancel()
    await oldControl.waitUntilCompletionDelivered()
    await #expect(throws: UpdateDownloadFailureReason.cancelled) {
        try await oldTask.value
    }

    let newTask = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/new.zip")!,
            to: newDestination,
            progress: { _ in }
        )
    }
    await newControl.waitUntilStarted()
    await oldControl.finish(.success(.init(
        statusCode: 200,
        temporaryURL: URL(fileURLWithPath: "/tmp/old-source.zip")
    )))
    await newControl.finish(.success(.init(
        statusCode: 200,
        temporaryURL: URL(fileURLWithPath: "/tmp/new-source.zip")
    )))

    #expect(try await newTask.value == newDestination)
}

@Test("取消在启动评估前不会启动传输，新的下载可以重试")
func adapterCancellationBeforeStartEvaluationAllowsRetry() async {
    let firstControl = AdapterTransportControl()
    let secondControl = AdapterTransportControl()
    let evaluation = StartEvaluationSignal()
    let barrier = StartEvaluationBarrier(signal: evaluation)
    let transportFactory = AdapterTransportFactory(controls: [firstControl, secondControl])
    let startGateFactory = DownloadStartGateFactory(gates: [
        DownloadStartGate(beforeEvaluation: { barrier.evaluate() }),
        DownloadStartGate()
    ])
    let adapter = URLSessionUpdatePackageDownloader(
        transportFactory: { transportFactory.makeTransport() },
        startGateFactory: { startGateFactory.makeGate() },
        fileManager: RecordingFileManager(moveError: nil)
    )

    let firstTask = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/first.zip")!,
            to: URL(fileURLWithPath: "/tmp/first.zip"),
            progress: { _ in }
        )
    }
    await evaluation.waitUntilEvaluated()
    adapter.cancel()
    barrier.release()

    await #expect(throws: UpdateDownloadFailureReason.cancelled) {
        try await firstTask.value
    }
    #expect(await firstControl.startedCount == 0)

    let retryTask = Task {
        try await adapter.download(
            from: URL(string: "https://example.com/retry.zip")!,
            to: URL(fileURLWithPath: "/tmp/retry.zip"),
            progress: { _ in }
        )
    }
    await secondControl.waitUntilStarted()
    await secondControl.finish(.success(.init(
        statusCode: 200,
        temporaryURL: URL(fileURLWithPath: "/tmp/retry-source.zip")
    )))
    let retryResult = try? await retryTask.value
    #expect(retryResult == URL(fileURLWithPath: "/tmp/retry.zip"))
}

@Test("URLSession delegate 转发响应并过滤其他任务")
func transportDelegateForwardsResponseAndFiltersOtherTask() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HangingURLProtocol.self]
    let transport = URLSessionUpdateDownloadTransport(configuration: configuration)
    let recorder = TransportResultRecorder()
    let temporaryURL = URL(fileURLWithPath: "/tmp/delegate-response.zip")

    transport.startDownload(
        from: URL(string: "https://example.com/source.zip")!,
        progress: { _ in },
        completion: { recorder.record($0) }
    )
    guard let activeTask = transport.activeTask else {
        Issue.record("transport 应保存活动任务")
        return
    }
    let otherTask = transport.session.downloadTask(
        with: URL(string: "https://example.com/other.zip")!
    )

    transport.urlSession(
        transport.session,
        downloadTask: otherTask,
        didFinishDownloadingTo: URL(fileURLWithPath: "/tmp/ignored.zip")
    )
    #expect(recorder.results.isEmpty)

    transport.urlSession(
        transport.session,
        downloadTask: activeTask,
        didFinishDownloadingTo: temporaryURL
    )

    guard case let .success(response) = recorder.results.first else {
        Issue.record("delegate 应转发完成响应")
        return
    }
    #expect(response.statusCode == nil)
    #expect(response.temporaryURL == temporaryURL)
    #expect(transport.activeTask == nil)
}

@Test("URLSession delegate 转发错误并将文件读取错误安全归类")
func transportDelegateForwardsAndMapsErrors() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HangingURLProtocol.self]
    let transport = URLSessionUpdateDownloadTransport(configuration: configuration)
    let recorder = TransportResultRecorder()

    transport.startDownload(
        from: URL(string: "https://example.com/source.zip")!,
        progress: { _ in },
        completion: { recorder.record($0) }
    )
    guard let activeTask = transport.activeTask else {
        Issue.record("transport 应保存活动任务")
        return
    }
    let otherTask = transport.session.downloadTask(
        with: URL(string: "https://example.com/other.zip")!
    )

    transport.urlSession(
        transport.session,
        task: otherTask,
        didCompleteWithError: URLError(.cannotOpenFile)
    )
    #expect(recorder.results.isEmpty)

    transport.urlSession(
        transport.session,
        task: activeTask,
        didCompleteWithError: URLError(.cannotOpenFile)
    )

    guard case let .failure(error) = recorder.results.first else {
        Issue.record("delegate 应转发错误响应")
        return
    }
    #expect(error as? UpdateDownloadFailureReason == .fileRead)
    #expect(transport.activeTask == nil)
}

@Test("URLSession transport 终止后失效并释放 delegate 生命周期")
func transportInvalidatesSessionAfterCancellation() async {
    let invalidation = InvalidationSignal()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HangingURLProtocol.self]
    let transport = URLSessionUpdateDownloadTransport(
        configuration: configuration,
        onSessionInvalidated: {
            Task { await invalidation.mark() }
        }
    )

    transport.startDownload(
        from: URL(string: "https://example.com/source.zip")!,
        progress: { _ in },
        completion: { _ in }
    )
    transport.cancel()

    await invalidation.wait()
    #expect(transport.activeTask == nil)
}

@Test("URLSession 生命周期按响应、进度、完成顺序只回调一次")
func delegateLifecycleReportsResponseProgressAndFinish() {
    let recorder = LifecycleRecorder()
    let lifecycle = URLSessionDownloadLifecycle(
        progress: { recorder.progress.append($0) },
        completion: { recorder.results.append($0) }
    )
    let temporaryURL = URL(fileURLWithPath: "/tmp/lifecycle.zip")

    lifecycle.receiveResponse(statusCode: 200)
    lifecycle.didWrite(totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
    lifecycle.didFinishDownloading(to: temporaryURL)
    lifecycle.didComplete(withError: UpdateDownloadFailureReason.transport)

    #expect(recorder.progress == [0.5])
    #expect(recorder.results.count == 1)
    guard case let .success(response) = recorder.results.first else {
        Issue.record("生命周期应返回成功响应")
        return
    }
    #expect(response.statusCode == 200)
    #expect(response.temporaryURL == temporaryURL)
}

@Test("URLSession 生命周期取消后忽略迟到完成")
func delegateLifecycleIgnoresLateCompletionAfterCancel() {
    let recorder = LifecycleRecorder()
    let lifecycle = URLSessionDownloadLifecycle(
        progress: { recorder.progress.append($0) },
        completion: { recorder.results.append($0) }
    )

    lifecycle.cancel()
    lifecycle.didFinishDownloading(to: URL(fileURLWithPath: "/tmp/late.zip"))
    lifecycle.didComplete(withError: UpdateDownloadFailureReason.transport)

    #expect(recorder.progress.isEmpty)
    #expect(recorder.results.count == 1)
    guard case let .failure(error) = recorder.results.first else {
        Issue.record("取消后生命周期应返回失败结果")
        return
    }
    #expect(error as? UpdateDownloadFailureReason == .cancelled)
}

@Test("URLSession 生命周期错误先于完成时忽略迟到文件")
func delegateLifecycleReportsErrorBeforeFinish() {
    let recorder = LifecycleRecorder()
    let lifecycle = URLSessionDownloadLifecycle(
        progress: { recorder.progress.append($0) },
        completion: { recorder.results.append($0) }
    )

    lifecycle.receiveResponse(statusCode: 200)
    lifecycle.didComplete(withError: UpdateDownloadFailureReason.transport)
    lifecycle.didFinishDownloading(to: URL(fileURLWithPath: "/tmp/late-error.zip"))

    #expect(recorder.results.count == 1)
    guard case let .failure(error) = recorder.results.first else {
        Issue.record("错误事件应先结束生命周期")
        return
    }
    #expect(error as? UpdateDownloadFailureReason == .transport)
}

@Test("URLSession 生命周期将取消错误映射为取消类别")
func delegateLifecycleMapsCancellationError() {
    let recorder = LifecycleRecorder()
    let lifecycle = URLSessionDownloadLifecycle(
        progress: { recorder.progress.append($0) },
        completion: { recorder.results.append($0) }
    )

    lifecycle.didComplete(withError: URLError(.cancelled))

    guard case let .failure(error) = recorder.results.first else {
        Issue.record("取消错误应结束生命周期")
        return
    }
    #expect(error as? UpdateDownloadFailureReason == .cancelled)
}

@Test("URLSession 生命周期将文件读取错误映射为文件读取类别")
func delegateLifecycleMapsFileReadError() {
    let recorder = LifecycleRecorder()
    let lifecycle = URLSessionDownloadLifecycle(
        progress: { recorder.progress.append($0) },
        completion: { recorder.results.append($0) }
    )

    lifecycle.didComplete(withError: URLError(.cannotOpenFile))

    guard case let .failure(error) = recorder.results.first else {
        Issue.record("文件读取错误应结束生命周期")
        return
    }
    #expect(error as? UpdateDownloadFailureReason == .fileRead)
}

@Test("生命周期终止不会越过进行中的进度回调")
func delegateLifecycleSerializesProgressAndTerminalEvents() {
    let progressEntered = DispatchSemaphore(value: 0)
    let releaseProgress = DispatchSemaphore(value: 0)
    let finishStarted = DispatchSemaphore(value: 0)
    let finishReturned = DispatchSemaphore(value: 0)
    let recorder = TerminalOrderingRecorder()
    let lifecycle = URLSessionDownloadLifecycle(
        progress: { value in
            recorder.recordProgress(value)
            progressEntered.signal()
            releaseProgress.wait()
        },
        completion: { _ in
            recorder.recordCompletion()
        }
    )

    DispatchQueue.global().async {
        lifecycle.didWrite(totalBytesWritten: 50, totalBytesExpectedToWrite: 100)
    }
    progressEntered.wait()

    DispatchQueue.global().async {
        finishStarted.signal()
        lifecycle.didFinishDownloading(to: URL(fileURLWithPath: "/tmp/ordered.zip"))
        finishReturned.signal()
    }
    finishStarted.wait()
    #expect(!recorder.completionWasCalled)

    releaseProgress.signal()
    finishReturned.wait()
    #expect(recorder.events == ["progress", "completion"])
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    private var waiters: [(Int, CheckedContinuation<[Double], Never>)] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        let ready = waiters.filter { values.count >= $0.0 }
        waiters.removeAll { values.count >= $0.0 }
        let snapshot = values
        lock.unlock()

        ready.forEach { $0.1.resume(returning: snapshot) }
    }

    func waitForValues(_ count: Int) async -> [Double] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if values.count >= count {
                let snapshot = values
                lock.unlock()
                continuation.resume(returning: snapshot)
                return
            }
            waiters.append((count, continuation))
            lock.unlock()
        }
    }
}

private final class LifecycleRecorder: @unchecked Sendable {
    var progress: [Double] = []
    var results: [Result<UpdateDownloadTransportResponse, Error>] = []
}

private final class TransportResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [Result<UpdateDownloadTransportResponse, Error>] = []

    func record(_ result: Result<UpdateDownloadTransportResponse, Error>) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }
}

private final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {}
}

private actor InvalidationSignal {
    private var didInvalidate = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        didInvalidate = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !didInvalidate else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor StartEvaluationSignal {
    private var didEvaluate = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        didEvaluate = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilEvaluated() async {
        guard !didEvaluate else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class StartEvaluationBarrier: @unchecked Sendable {
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let signal: StartEvaluationSignal

    init(signal: StartEvaluationSignal) {
        self.signal = signal
    }

    func evaluate() {
        Task { await signal.mark() }
        releaseSemaphore.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class TerminalOrderingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []

    var completionWasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains("completion")
    }

    func recordProgress(_ value: Double) {
        #expect(value == 0.5)
        lock.lock()
        events.append("progress")
        lock.unlock()
    }

    func recordCompletion() {
        lock.lock()
        events.append("completion")
        lock.unlock()
    }
}
