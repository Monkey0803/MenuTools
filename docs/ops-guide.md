# MenuTools 开发者指南 - 右键菜单操作实现

本文档面向需要为 Finder 右键菜单添加新操作的开发者，介绍核心组件、调用流程与最佳实践。

---

## 📚 架构概览

```
FinderSyncExtension (扩展进程)
    ↓ menu() → RightClickMenuBuilder
    ↓ nodes + RightClickCommandRegistry
    ↓ NSMenu items with tags
Finder 用户点击菜单项
    ↓ performCommand(sender: NSMenuItem)
    ↓ RightClickCommandDispatcher
    ↓ DistributedNotificationCenter
主 App (RightClickCommandHandler)
    ↓ RightClickConfigStore.load()
    ↓ RightClickCommandPolicy.validate()
    ↓ execute() → Service implementations
```

### 关键组件职责

| 组件 | 职责 | 线程/上下文 |
|------|------|-------------|
| `FinderSyncExtension` | 菜单构建与渲染，命令注册 | Finder 扩展进程，@MainActor |
| `RightClickCommandHandler` | 接收命令、验证、执行 | 主 App，@MainActor |
| `RightClickLogger` | 持久化日志 + 控制台输出 | @MainActor |
| `RightClickPerformanceMonitor` | 菜单构建时间戳追踪 | @MainActor |
| Services (`RightClickFileService` 等) | 实际文件操作 | Task.detached |

---

## 🛠 实现新操作的步骤

### Step 1: 定义操作类型

在 `Sources/MenuTools/RightClickItem.swift`（或类似文件）中添加枚举 case：

```swift
enum RightClickItem {
    // ... existing cases
    
    case newCustomFile
    case customOperation
}
```

### Step 2: 配置操作元数据

在 `Sources/MenuTools/Services/RightClickItem.swift` 中定义该操作的所有属性：

```swift
extension RightClickItem {
    var titleKey: String {
        switch self {
        case .newCustomFile: return "rc.item.newCustomFile"
        // ...
        }
    }
    
    var group: Group {
        .fileActions  // 或 .copy, .directory, .other
    }
    
    var symbolName: String? {
        ".star.fill"  // SF Symbol 名称
    }
}
```

### Step 3: 实现服务逻辑

创建新的 Service 或在现有 Service 中添加方法：

```swift
// Sources/MenuTools/Services/RightClickCustomFileService.swift
enum RightClickCustomFileService {
    static func create(in directory: URL, name: String) async throws -> URL {
        let fileURL = directory.appendingPathComponent(name)
        
        // 检查是否已存在
        if FileManager.default.fileExists(atPath: fileURL.path) {
            throw RightClickFileError.alreadyExists
        }
        
        // 创建文件或写入初始内容
        try "\(initialContent)".write(to: fileURL, atomically: true, encoding: .utf8)
        
        return fileURL
    }
}
```

### Step 4: 在 CommandHandler 中集成

编辑 `Sources/MenuTools/Services/RightClickCommandHandler.swift`：

```swift
private static func execute(_ item: RightClickItem, command: RightClickCommand, 
                           config: RightClickConfig) async throws {
    // ... existing code
    
    switch item {
    // ... existing cases
    
    case .newCustomFile:
        guard let name = promptName(title: L(item.titleKey), directory: first, initial: "custom") 
        else { return }
        
        let created = try await Task.detached {
            try RightClickCustomFileService.create(in: first, name: name)
        }.value
        
        showMessage("Created \(created.lastPathComponent)", title: L(item.titleKey))
        
        reveal([created])
        
    default:
        throw RightClickCommandError.invalidCommand
    }
}
```

### Step 5: 国际化文案

在所有语言的 `Resources/*/lproj/Localizable.strings` 中添加 key：

**en.lproj/Localizable.strings:**
```strings
"rc.item.newCustomFile" = "New Custom File";
```

**zh-Hans.lproj/Localizable.strings:**
```strings
"rc.item.newCustomFile" = "新建自定义文件";
```

重复所有语言文件，包括 `ja.lproj`, `ko.lproj`, `zh-Hant.lproj`。

### Step 6: 测试覆盖

在新文件 `Tests/MenuToolsTests/RightClickCustomFileServiceTests.swift` 中添加 TDD 测试：

```swift
final class RightClickCustomFileServiceTests: XCTestCase {
    func test_creates_file_in_directory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = try await RightClickCustomFileService.create(
            in: tempDir, name: "test.txt")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }
    
    func test_throws_when_exists() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("existing.txt")
        
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)
        
        do {
            _ = try await RightClickCustomFileService.create(in: tempDir, name: "existing.txt")
            XCTFail("Should throw alreadyExists error")
        } catch RightClickFileError.alreadyExists {
            // expected
        }
    }
}
```

### Step 7: 运行测试并修复

```bash
swift test --filter RightClickCustomFileServiceTests
```

确保所有测试通过。

---

## 🔍 调试技巧

### 查看错误日志

当操作失败时：

```bash
# 实时跟踪日志
tail -f ~/Library/Application\ Support/com.monkey0803.MenuTools/operations.log

# 筛选特定级别的日志
grep ERROR ops.log
grep PERF ops.log
```

### 启用/禁用日志记录

通过代码或设置开关控制：

```swift
RightClickLogger.enable()
RightClickLogger.disable()

// 读取最近 10 条日志
let recentLogs = RightClickLogger.readRecent(count: 10)
```

### 性能监控输出

菜单构建时会自动输出性能报告：

```bash
grep "Menu total:" ~/Library/Application\ Support/com.monkey0803.MenuTools/operations.log
```

示例输出：
```
[2026-09-18T10:03:49Z] PERF: 📊 Menu total: 145ms — phases: [(payload_read: 5ms), (context_build: 12ms), (nodes_build: 98ms), (menu_render: 30ms)]
```

### 诊断问题流程

1. **扩展未显示**: 打开健康检查页面，确认 `Finder Extension Status` 为 Enabled
2. **权限拒绝**: 检查 `Automation Permission` 状态
3. **操作失败**: 查看日志中的 `ERROR` 级别消息
4. **响应慢**: 分析 `PERF` 日志找出耗时最长阶段

---

## 🎯 最佳实践

### 错误处理原则

1. **明确错误类型**: 使用 `RightClickFileError` 或 `RightClickCommandError` 的规范错误枚举
2. **友好提示**: 将技术错误转换为用户可理解的消息
3. **不崩溃**: 所有异步操作都应在 `Task` 中包裹异常捕获
4. **记录日志**: 任何失败都必须写入 `RightClickLogger.error()`

### 并发安全

```swift
// ✅ 正确：后台执行 IO 密集操作
let result = try await Task.detached {
    try heavyIOOperation()
}.value

// ❌ 错误：在主线程执行长时间阻塞
heavyIOOperation()  // 会冻结 UI
```

### 缓存策略

对于重复操作（如大目录列表），建议使用缓存避免重复遍历：

```swift
@Sendable
class DirectoryListingCache {
    static let shared = DirectoryListingCache()
    private var cache: [URL: [String]] = [:]
    
    func get(for directory: URL) -> [String]? {
        cache[directory]
    }
    
    func set(_ items: [String], for directory: URL, ttl: TimeInterval = 300) {
        cache[directory] = items
        scheduleCleanup(directory, after: ttl)
    }
}
```

---

## 📝 常见问题

### Q: 如何让新操作只在特定文件类型上显示？

A: 在 `RightClickMenuPolicy.visibleItems(config:context:)` 中添加过滤条件：

```swift
case .mySpecialOp:
    return context.selection.allSatisfy { url in
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
```

### Q: 如何获取 Finder 选中的多个文件？

A: 通过 `command.paths` 获取：

```swift
let urls = command.paths.map { URL(fileURLWithPath: $0) }
guard !urls.isEmpty else { throw RightClickCommandError.noSelection }
```

### Q: 如何在操作中弹出输入框？

A: 使用现有的 `promptText` 辅助函数：

```swift
guard let name = promptText(
    title: "Enter filename",
    message: "Required",
    initial: "",
    placeholder: "My File"
) else { return }
```

### Q: 如何撤销操作？

A: 如果操作涉及移动/复制/新建，先调用：

```swift
let entries = try await undoRecord.entries
try RightClickUndoStore.save(.init(kind: .move, entries: entries))
```

然后用户可通过「撤销最近操作」菜单项恢复。

---

## 🔄 后续优化方向

1. **缓存预加载**: 对于大目录，提前在后台收集元数据而非阻塞菜单
2. **批量操作队列**: 支持连续执行多个相似操作（如批量修改权限）
3. **进度反馈**: 长操作显示进度条和取消按钮
4. **拖放增强**: 允许从其他应用拖入路径到 Finder 右键菜单（需 App Group 支持）

---

*本文档基于 Project:MenuTools v1.1.4+ 编写，持续更新中。*
