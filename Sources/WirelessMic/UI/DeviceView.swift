// DeviceView.swift
// 设备页：Win 版 DevicePage 同款白卡片——设备状态行、连接操作、诊断日志、权限引导。

import AppKit
import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var engine: MicEngine

    private var isConnected: Bool {
        if case .connected = engine.connectionState { return true }
        return false
    }

    private var isBusy: Bool {
        switch engine.connectionState {
        case .scanning, .connecting: return true
        default: return false
        }
    }

    private var deviceName: String {
        if case .connected(let name) = engine.connectionState { return name }
        return "—"
    }

    private var statusText: String {
        switch engine.connectionState {
        case .connected: return "已连接"
        case .scanning, .connecting: return "连接中…"
        case .disconnected: return "未连接"
        case .unauthorized: return "未授权"
        case .unsupported: return "不支持"
        case .failed(let reason): return reason
        }
    }

    private var statusColor: Color {
        switch engine.connectionState {
        case .connected: return Theme.success
        case .scanning, .connecting: return Theme.voiceAccent
        case .unauthorized, .unsupported, .failed: return Theme.error
        case .disconnected: return Theme.disabledText
        }
    }

    /// 蓝牙未授权时显示权限引导。
    private var showPermissionGuide: Bool {
        if case .unauthorized = engine.connectionState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 设备状态
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemeSectionTitle(text: "设备状态")
                        .padding(10)
                    Divider()
                    ThemeRow(label: "当前设备") {
                        Text(deviceName)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(statusColor)
                    }
                    .padding(10)
                    Divider()
                    // 语音输出走哪块虚拟声卡，一眼能对上语音页的设置。
                    ThemeRow(label: "输出设备") {
                        Text(engine.settings.outputDeviceName)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .padding(10)
                    Divider()
                    ThemeRow(label: "连接操作") {
                        Button("连接") { engine.start() }
                            .buttonStyle(ThemePrimaryButtonStyle())
                            .disabled(isConnected || isBusy)
                        Button("断开") { engine.stop() }
                            .buttonStyle(ThemeSecondaryButtonStyle())
                            .disabled(!isConnected && !isBusy)
                        Button("重新连接") { engine.reconnect() }
                            .buttonStyle(ThemeSecondaryButtonStyle())
                            .disabled(isBusy)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            // 诊断日志：整份复制（单行 Text 只能逐行选，复制整份日志必须走按钮）。
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        ThemeSectionTitle(text: "诊断日志")
                        Spacer()
                        Button("复制日志") {
                            let text = engine.logLines.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .buttonStyle(ThemeSecondaryButtonStyle())
                        Button("清空") { engine.clearLog() }
                            .buttonStyle(ThemeSecondaryButtonStyle())
                    }
                    .padding(10)
                    Divider()
                    logView
                        .padding(10)
                }
            }
            // 权限提示（蓝牙未授权时显示）
            if showPermissionGuide {
                ThemeCard {
                    PermissionGuide(bluetoothUnauthorized: true)
                        .padding(10)
                }
            }
        }
        .padding(10)
    }

    /// 日志区：滚动显示，新增日志自动滚到底部（只显示最近 500 行）。
    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let lines = Array(engine.logLines.suffix(500))
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .id(index)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: engine.logLines.count) { _, _ in scrollToBottom(proxy) }
        }
        .background(Theme.fieldBackground)
        .cornerRadius(Theme.controlRadius)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let count = Array(engine.logLines.suffix(500)).count
        if count > 0 {
            proxy.scrollTo(count - 1, anchor: .bottom)
        }
    }
}
