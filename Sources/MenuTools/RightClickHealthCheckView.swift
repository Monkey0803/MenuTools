import AppKit
import SwiftUI
import FinderSync

/// 健康检查页面 - 显示扩展状态与权限诊断
struct RightClickHealthCheckView: View {
    @StateObject private var extensionStatus = FinderSyncExtensionStatusService()
    @State private var configurationCommunicationAvailable = false
    @State private var automationPermission = false
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

                // 配置与扩展通信状态；App Group 不可用时会走本地存储与通知回退。
                StatusCard(
                    title: L("health.appgroup.name"),
                    description: L("health.appgroup.desc"),
                    isHealthy: configurationCommunicationAvailable,
                    actionButton: nil
                )

                Divider()

                // 自动化权限
                StatusCard(
                    title: L("health.automation.name"),
                    description: L("health.automation.desc"),
                    isHealthy: automationPermission,
                    actionButton: nil
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
    }
    
    // MARK: - Private Helpers
    
    private func diagnose() {
        // 扩展启用状态
        extensionStatus.refresh(finderAPIEnabled: FIFinderSyncController.isExtensionEnabled)
        
        // App Group 必须真的可写；自签名包可能遇到 EPERM，此时配置会回退到本地目录，
        // 并由分布式通知把变更同步给 Finder 扩展。
        configurationCommunicationAvailable = RightClickConfigStore.isWritableDirectory(
            RightClickConfigStore.resolveBaseDirectory()
        )
        
        // 自动化权限检查
        automationPermission = checkAutomationPermission()
        
        // 日志文件存在性
        logFileExists = FileManager.default.fileExists(atPath: RightClickLogger.logFile.path)
    }
    
    private func checkAutomationPermission() -> Bool {
        AXIsProcessTrusted()
    }
    
    private var openSettingsButton: some View {
        Button(L("health.button.openSettings")) {
            FIFinderSyncController.showExtensionManagementInterface()
        }
        .buttonStyle(.borderedProminent)
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
