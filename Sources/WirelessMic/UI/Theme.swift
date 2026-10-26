// Theme.swift
// 设计 token：照搬社区 Win 版 Tokens.qml 的配色与尺寸（浅色值 / 深色值），
// 让 Mac 界面与 Win 版同款：浅灰底、白卡片、细边框、#087cf0 蓝色主色。
// 颜色用动态 NSColor 实现，随系统浅色/深色模式自动切换。

import SwiftUI
import AppKit

enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { $0.name == .darkAqua ? dark : light }))
    }

    private static func hex(_ rgb: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    static let background = dynamic(light: hex(0xF5F6F8), dark: hex(0x171A1F))
    static let surface = dynamic(light: .white, dark: hex(0x20242B))
    static let surfaceMuted = dynamic(light: hex(0xF1F3F5), dark: hex(0x282D35))
    static let sidebar = dynamic(light: hex(0xF5F6F8), dark: hex(0x1B1E24))
    static let textPrimary = dynamic(light: hex(0x17191D), dark: hex(0xF3F4F6))
    static let textSecondary = dynamic(light: hex(0x5F6670), dark: hex(0xAEB4BE))
    static let disabledText = dynamic(light: hex(0x858C95), dark: hex(0x888F99))
    static let border = dynamic(light: hex(0xE2E4E7), dark: hex(0x343941))
    static let borderStrong = dynamic(light: hex(0xCFD4DA), dark: hex(0x474D57))
    static let accent = Color(hex: 0x087CF0)
    static let accentSoft = dynamic(light: hex(0xE7F2FF), dark: hex(0x183653))
    static let fieldBackground = dynamic(light: hex(0xF7F8F9), dark: hex(0x252A31))
    static let success = dynamic(light: hex(0x119C4C), dark: hex(0x64D78D))
    static let error = dynamic(light: hex(0xC42B1C), dark: hex(0xFF6764))
    static let voiceAccent = dynamic(light: hex(0xAA6410), dark: hex(0xEFB66B))

    static let cardRadius: CGFloat = 7
    static let controlRadius: CGFloat = 5
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Win 版同款白卡片：白底 + 细边框 + 7 圆角；选中时蓝底 + 蓝边。
struct ThemeCard<Content: View>: View {
    var selected: Bool = false
    /// 悬停：只给卡片一层浅灰底，绝不用蓝色——蓝色只留给“选中”，避免图上同时出现两个蓝圈。
    var hovered: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(selected ? Theme.accentSoft : (hovered ? Theme.surfaceMuted : Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(selected ? Theme.accent : (hovered ? Theme.borderStrong : Theme.border), lineWidth: 0.5)
            )
            .cornerRadius(Theme.cardRadius)
    }
}

/// Win 版同款分区标题（14 号半粗）。
struct ThemeSectionTitle: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Win 版同款行：左标签 + 内容 + 右侧状态/按钮。
struct ThemeRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 72, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Win 版同款主按钮：蓝底白字；次按钮：浅灰底。
struct ThemePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(configuration.isPressed ? Theme.accent.opacity(0.8) : Theme.accent)
            .foregroundStyle(.white)
            .cornerRadius(Theme.controlRadius)
    }
}

struct ThemeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(configuration.isPressed ? Theme.border : Theme.surfaceMuted)
            .foregroundStyle(Theme.textPrimary)
            .cornerRadius(Theme.controlRadius)
    }
}
