import AppKit
import SwiftUI
import FinderSync

/// 健康检查页面 - 显示扩展状态与权限诊断
struct RightClickHealthCheckView: View {
    @StateObject private var extensionStatus = FinderSyncExtensionStatusService()
    @State private var configurationStorageWritable = false
    @State private var accessibilityPermission = false
    @State private var logFileExists = false
    
    /// 日志开关存在共享配置里（扩展进程同样读得到），设置页在「Finder 右键菜单 → 诊断」。
    private var loggerEnabled: Bool { RightClickLogger.isEnabled }
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // 扩展启用状态
                StatusCard(
                    title: L("health.extension.enabled"),
                    description: L("health.extension.desc"),
                    isHealthy: extensionStatus.state.isAvailable,
                    actionButton: AnyView(openSettingsButton)
                )

                Divider()

                // 只检查当前进程实际使用的配置目录是否可写，不推断扩展通信状态。
                StatusCard(
                    title: L("health.storage.name"),
                    description: L("health.storage.desc"),
                    isHealthy: configurationStorageWritable,
                    actionButton: nil
                )

                Divider()

                // AXIsProcessTrusted 只表示辅助功能授权，不代表自动化授权。
                StatusCard(
                    title: L("health.accessibility.name"),
                    description: L("health.accessibility.desc"),
                    isHealthy: accessibilityPermission,
                    actionButton: accessibilityPermission ? nil : AnyView(openAccessibilityButton)
                )

                Divider()

                // 日志存储状态
                StatusCard(
                    title: L("health.logging.name"),
                    description: L("health.logging.desc"),
                    isHealthy: logFileExists || !loggerEnabled,
                    actionButton: AnyView(showLogsButton)
                )

                Spacer(minLength: 8)
            }
            .padding(.vertical, 4)
        } label: {
            Label(L("health.title"), systemImage: "checkmark.shield")
        }
        .glassEffect()
        .padding(SettingsScrollLayout.contentInsets())
        .frame(width: SettingsLayout.width, height: SettingsLayout.height, alignment: .top)
        .onAppear(perform: diagnose)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            diagnose()
        }
    }
    
    // MARK: - Private Helpers
    
    private func diagnose() {
        // 扩展启用状态
        extensionStatus.refresh(finderAPIEnabled: FIFinderSyncController.isExtensionEnabled)
        
        // fileURL 是配置读写实际使用的路径；按该路径探测，避免重新选择候选目录。
        let configBase = RightClickConfigStore.fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        configurationStorageWritable = RightClickConfigStore.isWritableDirectory(configBase)
        
        accessibilityPermission = AXIsProcessTrusted()
        
        // 日志文件存在性
        logFileExists = FileManager.default.fileExists(atPath: RightClickLogger.logFile.path)
    }
    
    private var openSettingsButton: some View {
        Button(L("health.button.openSettings")) {
            FIFinderSyncController.showExtensionManagementInterface()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var openAccessibilityButton: some View {
        Button(L("health.button.openAccessibility")) {
            guard let url = RuntimePermissionSettingsLink.url(for: .accessibility) else { return }
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    
    private var showLogsButton: some View {
        Button(L("health.button.viewLogs")) {
            NSWorkspace.shared.open(RightClickLogger.logDirectory)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Status Card

private struct StatusCard: View {
    let title: String
    let description: String
    let isHealthy: Bool
    let actionButton: AnyView?
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status indicator
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(isHealthy ? .green : .red)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if let button = actionButton {
                    button
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(isHealthy ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        .cornerRadius(8)
    }
}

#if DEBUG
struct HealthCheckView_Previews: PreviewProvider {
    static var previews: some View {
        RightClickHealthCheckView()
    }
}
#endif
