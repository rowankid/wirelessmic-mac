// Shared.swift
// 跨模块共享类型：引擎与界面都只用这里定义的符号，禁止各自定义第二份。
// 注意：不要修改本文件的类型名与 rawValue（映射持久化与 SayAll 的按键命名对齐）。

import Foundation

// MARK: - 遥控器按键

/// Chromecast 语音遥控器（G9N9N）的普通按键。
/// rawValue 与 SayAll 公开仓的 ChromecastRemoteControl 对齐，便于对照。
enum RemoteButton: String, CaseIterable, Codable, Identifiable {
    case power
    case up
    case down
    case left
    case right
    case select
    case back
    case home
    case mute
    case youtube
    case netflix
    case input
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .power: return "电源"
        case .up: return "上"
        case .down: return "下"
        case .left: return "左"
        case .right: return "右"
        case .select: return "确认"
        case .back: return "返回"
        case .home: return "主页"
        case .mute: return "静音"
        case .youtube: return "YouTube"
        case .netflix: return "Netflix"
        case .input: return "输入源"
        case .volumeUp: return "音量+"
        case .volumeDown: return "音量-"
        }
    }

    /// 遥控器图上的布局行列（供 UI 画遥控器时使用，与 G9N9N 实物排布一致）。
    /// row 越大越靠下；col 0 = 左列，1 = 中列，2 = 右列。
    var gridPosition: (row: Int, col: Int) {
        switch self {
        case .power: return (0, 2)
        case .up: return (1, 1)
        case .down: return (3, 1)
        case .left: return (2, 0)
        case .right: return (2, 2)
        case .select: return (2, 1)
        case .back: return (4, 0)
        case .home: return (4, 2)
        case .mute: return (5, 0)
        case .youtube: return (6, 0)
        case .netflix: return (6, 2)
        case .input: return (5, 2)
        case .volumeUp: return (7, 1)
        case .volumeDown: return (8, 1)
        }
    }
}

// MARK: - 按键方式

enum PressKind: String, CaseIterable, Codable {
    case single
    case double
    case long

    var displayName: String {
        switch self {
        case .single: return "单击"
        case .double: return "双击"
        case .long: return "长按"
        }
    }
}

// MARK: - 按键组合（用于模拟键盘）

/// 一次键盘动作。Fn 用 flagsChanged 事件模拟（keyCode 63 + maskSecondaryFn），
/// 普通组合键用 keyDown/keyUp。display 是界面显示，如 "Fn"、"⌘←"、"⏎"。
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var isFn: Bool
    var display: String

    static let fn = KeyCombo(keyCode: 63, modifiers: 0, isFn: true, display: "Fn")
    static let enter = KeyCombo(keyCode: 36, modifiers: 0, isFn: false, display: "⏎")
    static let escape = KeyCombo(keyCode: 53, modifiers: 0, isFn: false, display: "⎋")
    static let upArrow = KeyCombo(keyCode: 126, modifiers: 0, isFn: false, display: "↑")
    static let downArrow = KeyCombo(keyCode: 125, modifiers: 0, isFn: false, display: "↓")
    static let leftArrow = KeyCombo(keyCode: 123, modifiers: 0, isFn: false, display: "←")
    static let rightArrow = KeyCombo(keyCode: 124, modifiers: 0, isFn: false, display: "→")
    /// 退格（Win 版返回键的默认动作，macOS keyCode 51）。
    static let deleteBackward = KeyCombo(keyCode: 51, modifiers: 0, isFn: false, display: "⌫")
    /// Mission Control（Win 版“显示桌面”在 Mac 上没有直接对应的可靠按键，改成它）。
    static let missionControl = KeyCombo(keyCode: 126, modifiers: 1 << 18, isFn: false, display: "⌃↑")
    /// 应用程序窗口（调度中心的 ⌃↓，等于三指下滑）。
    static let appWindows = KeyCombo(keyCode: 125, modifiers: 1 << 18, isFn: false, display: "⌃↓")
    /// 向左移动一个空间（调度中心的 ⌃←）。
    static let spaceLeft = KeyCombo(keyCode: 123, modifiers: 1 << 18, isFn: false, display: "⌃←")
    /// 向右移动一个空间（调度中心的 ⌃→）。
    static let spaceRight = KeyCombo(keyCode: 124, modifiers: 1 << 18, isFn: false, display: "⌃→")
    /// 切换输入源（Win 版输入源键的 Mac 适配，macOS 默认 ⌃空格）。
    static let inputSource = KeyCombo(keyCode: 49, modifiers: 1 << 18, isFn: false, display: "⌃空格")
    /// 应用切换器（SayAll Mac 版的 Command-Tab 功能，keyCode 48 + Command）。
    static let appSwitcher = KeyCombo(keyCode: 48, modifiers: 1 << 20, isFn: false, display: "⌘Tab")
}

// MARK: - 按键动作

enum ButtonAction: Codable, Equatable {
    case none
    case key(KeyCombo)
    case volumeUp
    case volumeDown
    case muteToggle
    case playPause
    case nextTrack
    case previousTrack

    var displayName: String {
        switch self {
        case .none: return "无动作"
        case .key(let combo): return "按键 \(combo.display)"
        case .volumeUp: return "音量+"
        case .volumeDown: return "音量-"
        case .muteToggle: return "静音切换"
        case .playPause: return "播放/暂停"
        case .nextTrack: return "下一曲"
        case .previousTrack: return "上一曲"
        }
    }
}

// MARK: - 语音模式与输入工具

enum VoiceMode: String, CaseIterable, Codable {
    case hold
    case toggle

    var displayName: String {
        switch self {
        case .hold: return "按住说话"
        case .toggle: return "按一次说话"
        }
    }
}

enum VoiceTool: String, CaseIterable, Codable {
    case doubao
    case wechat
    case sogou
    case other

    var displayName: String {
        switch self {
        case .doubao: return "豆包"
        case .wechat: return "微信输入法"
        case .sogou: return "搜狗输入法"
        case .other: return "其他"
        }
    }
}

// MARK: - 连接状态

enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case connected(String)
    case unauthorized
    case unsupported
    case failed(String)

    var displayName: String {
        switch self {
        case .disconnected: return "未连接"
        case .scanning: return "正在查找遥控器…"
        case .connecting: return "正在连接…"
        case .connected(let name): return "已连接：\(name)"
        case .unauthorized: return "蓝牙权限被拒绝"
        case .unsupported: return "此 Mac 不支持 BLE 中央模式"
        case .failed(let reason): return "连接失败：\(reason)"
        }
    }
}

// MARK: - 设置（JSON 持久化，见 SettingsStore）

struct AppSettings: Codable {
    var voiceMode: VoiceMode = .toggle
    var selectedTool: VoiceTool = .doubao
    /// key: VoiceTool.rawValue，value: 该工具的语音启动快捷键（默认 Fn）。
    var toolHotkeys: [String: KeyCombo] = [:]
    /// 虚拟麦克风输出设备名，默认 BlackHole 2ch。
    var outputDeviceName: String = "BlackHole 2ch"
    /// key: " <button.rawValue>#<pressKind.rawValue>"，value: 动作。
    var mappings: [String: ButtonAction] = [:]
    /// 按键配置预设：key 为预设名，value 为一整套映射（与 mappings 同格式）。
    var presets: [String: [String: ButtonAction]] = [:]
    var launchAtLogin: Bool = false

    static func mappingKey(button: RemoteButton, press: PressKind) -> String {
        "\(button.rawValue)#\(press.rawValue)"
    }

    /// 开箱默认映射：以 Win 版 Chromecast 默认表为底，按 Mac 调整——
    /// 返回改成退格（Win 版返回键默认），电源改成 Esc，主页改成 Mission Control
    /// （Win 版显示桌面在 Mac 上没有直接对应的可靠按键），输入源改成切换输入源
    /// （⌃空格）；YouTube/Netflix 默认禁用（即无动作）。双击/长按默认全空，与 Win 版一致。
    static var defaultMappings: [String: ButtonAction] {
        [
            mappingKey(button: .up, press: .single): .key(.upArrow),
            mappingKey(button: .down, press: .single): .key(.downArrow),
            mappingKey(button: .left, press: .single): .key(.leftArrow),
            mappingKey(button: .right, press: .single): .key(.rightArrow),
            mappingKey(button: .select, press: .single): .key(.enter),
            mappingKey(button: .back, press: .single): .key(.deleteBackward),
            mappingKey(button: .power, press: .single): .key(.escape),
            mappingKey(button: .home, press: .single): .key(.missionControl),
            mappingKey(button: .input, press: .single): .key(.inputSource),
            mappingKey(button: .volumeUp, press: .single): .volumeUp,
            mappingKey(button: .volumeDown, press: .single): .volumeDown,
            mappingKey(button: .mute, press: .single): .muteToggle,
        ]
    }

    /// v6 及之前的默认映射（仅 9 项）：用于一次性迁移——已存配置若与它完全一致，
    /// 说明用户从未改过映射，直接升级到新默认表；改过的配置一律不动。
    static var legacyDefaultMappings: [String: ButtonAction] {
        [
            mappingKey(button: .up, press: .single): .key(.upArrow),
            mappingKey(button: .down, press: .single): .key(.downArrow),
            mappingKey(button: .left, press: .single): .key(.leftArrow),
            mappingKey(button: .right, press: .single): .key(.rightArrow),
            mappingKey(button: .select, press: .single): .key(.enter),
            mappingKey(button: .back, press: .single): .key(.escape),
            mappingKey(button: .volumeUp, press: .single): .volumeUp,
            mappingKey(button: .volumeDown, press: .single): .volumeDown,
            mappingKey(button: .mute, press: .single): .muteToggle,
        ]
    }

    static var `default`: AppSettings {
        var settings = AppSettings()
        settings.mappings = defaultMappings
        return settings
    }
}
