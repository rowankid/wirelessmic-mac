// MainView.swift
// 主界面：照搬 Win 版 main.qml 的壳——左侧 48 宽图标导航（设备 / 按键 / 语音 / 设置），
// 右侧页面区 + 底部状态条。导航选中项为蓝色，其余灰色。

import SwiftUI

enum MainTab: Hashable {
    case device, buttons, voice, settings
}

struct MainView: View {
    @EnvironmentObject private var engine: MicEngine
    @State private var tab: MainTab = .device

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Theme.borderStrong)
                .frame(width: 1)
            VStack(spacing: 0) {
                content
                statusBar
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(Theme.background)
    }

    // MARK: - 左侧导航

    private var sidebar: some View {
        VStack(spacing: 3) {
            navButton(tab: .device, title: "设备", icon: "link")
            navButton(tab: .buttons, title: "按键", icon: "keyboard")
            navButton(tab: .voice, title: "语音", icon: "mic.fill")
            navButton(tab: .settings, title: "设置", icon: "gearshape")
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
        .frame(width: 48)
        .background(Theme.sidebar)
    }

    private func navButton(tab: MainTab, title: String, icon: String) -> some View {
        let selected = (self.tab == tab)
        return Button(action: { self.tab = tab }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(width: 40, height: 46)
            .background(selected ? Theme.accentSoft : Color.clear)
            .cornerRadius(Theme.controlRadius)
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 页面区

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .device:
            ScrollView {
                DeviceView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .buttons:
            ButtonMappingView(onOpenVoice: { tab = .voice })
        case .voice:
            ScrollView {
                VoiceView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .settings:
            ScrollView {
                SettingsView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 底部状态条（Win 版 globalStatusBar 同款）

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.background)
        .overlay(Rectangle().fill(Theme.border).frame(height: 0.5), alignment: .top)
    }

    private var statusText: String {
        if let last = engine.logLines.last, !last.isEmpty {
            return "\(engine.connectionState.displayName) · \(last)"
        }
        return engine.connectionState.displayName
    }
}
