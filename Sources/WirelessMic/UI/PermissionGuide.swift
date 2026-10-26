// PermissionGuide.swift
// 权限引导小组件：蓝牙、辅助功能两项，每项一句话说明 + 去设置按钮。设备页复用。
// 注意：辅助功能的实时授权状态需要 ApplicationServices 的 AXIsProcessTrusted，
// 本文件只用 SwiftUI + AppKit，因此不做实时检测，只做引导；蓝牙未授权由设备页根据引擎状态传入。

import SwiftUI

struct PermissionGuide: View {
    /// 蓝牙是否未授权（设备页根据引擎连接状态传入）；为 true 时该行显示未授权提醒。
    var bluetoothUnauthorized: Bool = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("权限")
                .font(.headline)
            permissionRow(
                title: "蓝牙",
                description: "用于发现并连接 Chromecast 遥控器。",
                urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
                showWarning: bluetoothUnauthorized
            )
            permissionRow(
                title: "辅助功能",
                description: "用于模拟键盘按键，把遥控器按键变成快捷键。",
                urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                showWarning: false
            )
        }
    }

    private func permissionRow(title: String, description: String, urlString: String, showWarning: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.semibold)
                    if showWarning {
                        Text("未授权")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("去设置") {
                if let url = URL(string: urlString) {
                    openURL(url)
                }
            }
        }
    }
}
