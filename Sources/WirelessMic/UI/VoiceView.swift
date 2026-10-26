// VoiceView.swift
// 语音页：Win 版 VoicePage 同款白卡片——音频前置、语音程序、测试验证。

import SwiftUI
import AppKit

struct VoiceView: View {
    @EnvironmentObject private var engine: MicEngine
    @State private var outputDeviceText = ""

    /// 输入工具选择：读引擎设置，改动直接调引擎方法（不绕开引擎写设置）。
    private var toolBinding: Binding<VoiceTool> {
        Binding(get: { engine.settings.selectedTool }, set: { engine.setTool($0) })
    }

    private var voiceModeBinding: Binding<VoiceMode> {
        Binding(get: { engine.settings.voiceMode }, set: { engine.setVoiceMode($0) })
    }

    /// 当前工具的语音启动快捷键，未配置时默认 Fn。
    private var hotkeyDisplay: String {
        engine.settings.toolHotkeys[engine.settings.selectedTool.rawValue]?.display ?? KeyCombo.fn.display
    }

    private var isConnected: Bool {
        if case .connected = engine.connectionState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 音频前置
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemeSectionTitle(text: "音频前置")
                        .padding(10)
                    Divider()
                    ThemeRow(label: "输出端点") {
                        TextField("BlackHole 2ch", text: $outputDeviceText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { engine.setOutputDevice(outputDeviceText) }
                        Button("应用") { engine.setOutputDevice(outputDeviceText) }
                            .buttonStyle(ThemeSecondaryButtonStyle())
                    }
                    .padding(10)
                    Text("声音输出到虚拟声卡，再由输入法或会议软件选用它作为麦克风。未安装 BlackHole 时这里不会出现该设备：装完按提示重启 Mac，重启后才出现。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10)
                    HStack(spacing: 8) {
                        Button("安装 BlackHole（官网）") {
                            if let url = URL(string: "https://existential.audio/blackhole") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(ThemeSecondaryButtonStyle())
                        Text("装 2ch 版即可")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                }
            }
            // 语音程序
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemeSectionTitle(text: "语音程序")
                        .padding(10)
                    Divider()
                    ThemeRow(label: "选择程序") {
                        Picker("选择程序", selection: toolBinding) {
                            ForEach(VoiceTool.allCases, id: \.self) { tool in
                                Text(tool.displayName).tag(tool)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .padding(10)
                    Divider()
                    ThemeRow(label: "按键模式") {
                        Picker("按键模式", selection: voiceModeBinding) {
                            ForEach(VoiceMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .padding(10)
                    Divider()
                    ThemeRow(label: "语音快捷键") {
                        Text(hotkeyDisplay)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                        Text("默认 Fn；如需改动请告知输入法与快捷键")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                }
            }
            // 测试验证
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemeSectionTitle(text: "测试验证")
                        .padding(10)
                    Divider()
                    ThemeRow(label: "语音状态") {
                        Circle()
                            .fill(engine.isVoiceActive ? Theme.success : Theme.disabledText)
                            .frame(width: 10, height: 10)
                        Text(engine.isVoiceActive ? "正在收音…" : "待机")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        // 注意：两种 ButtonStyle 不能写在一个 ?: 里，用 if/else 分开写。
                        if engine.isVoiceActive {
                            Button("停止语音") { engine.setVoiceActive(false) }
                                .buttonStyle(ThemeSecondaryButtonStyle())
                                .disabled(!isConnected)
                        } else {
                            Button("开始语音") { engine.setVoiceActive(true) }
                                .buttonStyle(ThemePrimaryButtonStyle())
                                .disabled(!isConnected)
                        }
                    }
                    .padding(10)
                    LevelMeter(level: engine.level, active: engine.isVoiceActive)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
        .padding(10)
        .onAppear { outputDeviceText = engine.settings.outputDeviceName }
        .onChange(of: engine.settings.outputDeviceName) { _, newValue in outputDeviceText = newValue }
    }
}

/// 语音电平条：level 0...1。
private struct LevelMeter: View {
    var level: Float
    var active: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.surfaceMuted)
                Capsule()
                    .fill(active ? Theme.success : Theme.accent)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(1, max(0, level)))))
            }
        }
        .frame(height: 10)
    }
}
