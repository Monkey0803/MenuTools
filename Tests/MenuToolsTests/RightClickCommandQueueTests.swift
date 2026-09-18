import Foundation
import Testing
@testable import MenuTools

@Test("命令队列按到达顺序串行出队")
func rightClickCommandQueueIsFIFO() {
    var queue = RightClickCommandQueue(capacity: 4)
    let first = RightClickCommand(action: "checksum", paths: ["/tmp/a"], requestID: "a")
    let second = RightClickCommand(action: "newFolder", paths: ["/tmp"], requestID: "b")

    #expect(queue.enqueue(first) == .accepted)
    #expect(queue.enqueue(second) == .accepted)
    #expect(queue.count == 2)
    #expect(queue.dequeue() == first)
    #expect(queue.dequeue() == second)
    #expect(queue.dequeue() == nil)
    #expect(queue.isEmpty)
}

@Test("命令队列拒绝重复请求但允许无 ID 的独立命令")
func rightClickCommandQueueRejectsDuplicates() {
    var queue = RightClickCommandQueue(capacity: 4)
    let command = RightClickCommand(action: "checksum", paths: ["/tmp/a"], requestID: "same")
    #expect(queue.enqueue(command) == .accepted)
    #expect(queue.enqueue(command) == .duplicate)
    #expect(queue.count == 1)

    let withoutID = RightClickCommand(action: "newFolder", paths: ["/tmp"])
    #expect(queue.enqueue(withoutID) == .accepted)
    #expect(queue.enqueue(withoutID) == .accepted)
    #expect(queue.count == 3)
}

@Test("命令队列达到容量后拒绝新命令并保持已排队顺序")
func rightClickCommandQueueRespectsCapacity() {
    var queue = RightClickCommandQueue(capacity: 2)
    #expect(queue.enqueue(.init(action: "checksum", paths: ["/tmp/1"], requestID: "1")) == .accepted)
    #expect(queue.enqueue(.init(action: "checksum", paths: ["/tmp/2"], requestID: "2")) == .accepted)
    #expect(queue.enqueue(.init(action: "checksum", paths: ["/tmp/3"], requestID: "3")) == .full)
    #expect(queue.count == 2)
    #expect(queue.dequeue()?.paths == ["/tmp/1"])
    #expect(queue.enqueue(.init(action: "checksum", paths: ["/tmp/3"], requestID: "3")) == .accepted)
    #expect(queue.count == 2)
}

@Test("命令队列容量至少为 1")
func rightClickCommandQueueClampsCapacity() {
    var queue = RightClickCommandQueue(capacity: 0)
    #expect(queue.enqueue(.init(action: "checksum", paths: ["/tmp/1"], requestID: "1")) == .accepted)
    #expect(queue.enqueue(.init(action: "checksum", paths: ["/tmp/2"], requestID: "2")) == .full)
}
