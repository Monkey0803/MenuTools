import Foundation

/// 右键命令的串行队列。
///
/// 之前的实现用布尔锁直接拒绝并发命令，用户在大文件复制期间点任何右键都会收到“正在处理”。
/// 现在改为排队：主进程一次只执行一项，其余命令按到达顺序等待。
struct RightClickCommandQueue {
    enum EnqueueResult: Equatable {
        case accepted
        case duplicate
        case full
    }

    static let defaultCapacity = 32

    private(set) var commands: [RightClickCommand] = []
    let capacity: Int

    init(capacity: Int = RightClickCommandQueue.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { commands.isEmpty }
    var count: Int { commands.count }

    /// 同一 requestID 的重复投递（定时重试与配置广播重投）只保留一份。
    mutating func enqueue(_ command: RightClickCommand) -> EnqueueResult {
        if let id = command.requestID, commands.contains(where: { $0.requestID == id }) {
            return .duplicate
        }
        guard commands.count < capacity else { return .full }
        commands.append(command)
        return .accepted
    }

    mutating func dequeue() -> RightClickCommand? {
        commands.isEmpty ? nil : commands.removeFirst()
    }

    mutating func removeAll() {
        commands.removeAll()
    }
}
