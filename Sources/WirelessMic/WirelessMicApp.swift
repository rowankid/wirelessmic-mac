// WirelessMicApp.swift
// 应用入口：主窗口 + 菜单栏。

import SwiftUI
import AppKit

/// Dock 图标开关（默认不显示：只在菜单栏常驻）。存在 UserDefaults，不进 settings.json。
enum DockIconPreference {
    static let key = "showDockIcon"

    static var showDockIcon: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    /// 应用激活策略：显示 Dock 图标用 .regular；只留菜单栏用 .accessory（无 Dock 图标、无 ⌘Tab 条目）。
    static func apply(_ show: Bool) {
        NSApplication.shared.setActivationPolicy(show ? .regular : .accessory)
        if show {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIconPreference.apply(DockIconPreference.showDockIcon)
    }
}

@main
struct WirelessMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = MicEngine()

    var body: some Scene {
        Window("无线麦", id: "main") {
            MainView()
                .environmentObject(engine)
        }
        .defaultSize(width: 880, height: 660)

        MenuBarExtra("无线麦", systemImage: "mic.fill") {
            MenuBarView()
                .environmentObject(engine)
        }
    }
}

/// 菜单栏菜单。
private struct MenuBarView: View {
    @EnvironmentObject private var engine: MicEngine
    @Environment(\.openWindow) private var openWindow

    private var isConnected: Bool {
        if case .connected = engine.connectionState { return true }
        return false
    }

    var body: some View {
        Text(engine.connectionState.displayName)
        Divider()
        if isConnected {
            Button("断开") { engine.stop() }
        } else {
            Button("连接") { engine.start() }
        }
        Button(engine.isVoiceActive ? "停止语音" : "开始语音") {
            engine.setVoiceActive(!engine.isVoiceActive)
        }
        .disabled(!isConnected)
        Divider()
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}
