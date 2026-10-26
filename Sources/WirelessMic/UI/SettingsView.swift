// SettingsView.swift
// 设置页：Win 版同款白卡片——启动、输出设备、关于。
// 开机启动用 SMAppService 直接注册/注销登录项（不经过引擎，因为契约没有对应方法），
// 失败时回滚开关并显示原因。

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var engine: MicEngine
    @State private var outputDeviceText = ""
    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var applyingLaunchChange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 启动
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemeSectionTitle(text: "启动")
                        .padding(10)
                    Divider()
                    ThemeRow(label: "开机启动") {
                        Toggle("开机启动", isOn: $launchAtLogin)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, newValue in
                                applyLaunchChange(newValue)
                            }
                        if let launchError {
                            Text(launchError)
                                .foregroundStyle(Theme.error)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(10)
                }
            }
            // 输出设备
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemeSectionTitle(text: "输出设备")
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
                }
            }
            // 关于
            ThemeCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemeSectionTitle(text: "关于")
                        .padding(10)
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("无线麦 Mac 版")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("版本 1.0.0")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Text("把 Chromecast 语音遥控器变成 Mac 的无线麦克风。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Text("遥控器实物图与 ATVV 协议实现参考社区 Win 版（ZSTDJan/windows-remote-mic-app，GPL-3.0）。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                }
            }
        }
        .padding(10)
        .onAppear {
            outputDeviceText = engine.settings.outputDeviceName
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
        .onChange(of: engine.settings.outputDeviceName) { _, newValue in outputDeviceText = newValue }
    }

    /// 开机启动开关逻辑：注册/注销登录项，失败时回滚到系统实际状态并显示原因。
    /// applyingLaunchChange 防止回滚赋值再次触发 onChange 造成循环。
    private func applyLaunchChange(_ enabled: Bool) {
        guard !applyingLaunchChange else { return }
        applyingLaunchChange = true
        defer { applyingLaunchChange = false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "设置开机启动失败：\(error.localizedDescription)"
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
