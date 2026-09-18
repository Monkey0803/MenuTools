import AppKit
import SwiftUI
import FinderSync

/// 健康检查页面 - 显示扩展状态与权限诊断
struct RightClickHealthCheckView: View {
    @State private var extensionEnabled = false
    @State private var appGroupAccessible = false
    @State private var automationPermission = false
    @State private var logFileExists = false
    
    @AppStorage("rc_logger_enabled") private var loggerEnabled = false
    
    var body: some View {
        GroupBox(label: Label("health.title", systemName: "checkmark.shield"))
            .frame(minWidth: 400)
            .glassEffect()
            .padding(.top, 12)
        
        VStack(alignment: .leading, spacing: 16) {
            // 扩展启用状态
            StatusCard(
                title: L("health.extension.enabled"),
                description: L("health.extension.desc"),
                isHealthy: extensionEnabled,
                actionButton: openSettingsButton
            )
            
            Divider()
            
            // App Group 访问状态
            StatusCard(
                title: L("health.appgroup.name"),
                description: L("health.appgroup.desc"),
                isHealthy: appGroupAccessible,
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
                actionButton: showLogsButton
            )
            
            Spacer(minLength: 8)
        }
        .onAppear(perform: diagnose)
    }
    
    // MARK: - Private Helpers
    
    private func diagnose() {
        // 扩展启用状态
        extensionEnabled = FIFinderSyncController.default().isExtensionEnabled
        
        // App Group 访问（简化为检查目录是否存在）
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("com.monkey0803.MenuTools")
        appGroupAccessible = FileManager.default.fileExists(atPath: directory.path)
        
        // 自动化权限检查
        automationPermission = checkAutomationPermission()
        
        // 日志文件存在性
        let logFile = directory.appendingPathComponent("operations.log")
        logFileExists = FileManager.default.fileExists(atPath: logFile.path)
    }
    
    private func checkAutomationPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    private var openSettingsButton: some View {
        Button(L("health.button.openSettings")) {
            NSWorkspace.shared.open(URL(string: "x-apple.systemsettings:preferences/?ID=com.apple.preference.security?Privacy_Automation")!)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
    
    private var showLogsButton: some View {
        Button(L("health.button.viewLogs")) {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("com.monkey0803.MenuTools")
            NSWorkspace.shared.open(directory)
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

// MARK: - Localization Extensions

extension String {
    init(literal key: String, systemName iconName: String) {
        self = String(localized: key, bundle: .main, value: "", comment: "")
    }
}

#if DEBUG
struct HealthCheckView_Previews: PreviewProvider {
    static var previews: some View {
        RightClickHealthCheckView()
    }
}
#endif
