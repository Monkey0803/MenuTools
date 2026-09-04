import SwiftUI

/// 由全局快捷键调出的紧凑窗口管理面板。
struct WindowManagementQuickAccessView: View {
    @State private var windowService = WindowManagementService.shared
    @State private var errorMessage: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("window.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                if let application = windowService.focusedApplicationInfo() {
                    Text(application.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(L("window.quickAccess.targetHint"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(WindowLayout.allCases) { layout in
                        Button {
                            apply(layout)
                        } label: {
                            HStack(spacing: 6) {
                                WindowLayoutIcon(layout: layout)
                                    .frame(width: 16, height: 12)
                                Text(L(layout.titleKey))
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .contentShape(.rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .controlCenterHover(shape: AnyShape(.rect(cornerRadius: 8)))
                        .accessibilityLabel(L(layout.titleKey))
                    }
                }
                .padding(.vertical, 2)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 340, height: 430, alignment: .top)
    }

    private func apply(_ layout: WindowLayout) {
        // 快捷键触发时服务已记录外部前台应用；此处不激活 MenuTools。
        do {
            try windowService.apply(layout)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
