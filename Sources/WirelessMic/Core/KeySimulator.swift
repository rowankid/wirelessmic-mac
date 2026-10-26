// KeySimulator.swift
// CGEvent 模拟按键：普通组合键、Fn 键、系统媒体键（音量/静音）。
// 需要辅助功能权限；缺权限时抛可读错误，不静默失败。

import Foundation
import ApplicationServices
import AppKit

enum KeySimulatorError: Error, LocalizedError {
    case accessibilityDenied
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "缺少辅助功能权限：请在系统设置 → 隐私与安全性 → 辅助功能里允许本应用，然后重试。"
        case .eventCreationFailed:
            return "无法创建模拟按键事件。"
        }
    }
}

/// 系统媒体键（IOKit ev_keymap.h 的 NX_KEYTYPE_* 值，subtype 固定为 8）。
enum MediaKey {
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case nextTrack
    case previousTrack

    /// NX_KEYTYPE_SOUND_UP = 0、NX_KEYTYPE_SOUND_DOWN = 1、NX_KEYTYPE_MUTE = 7、
    /// NX_KEYTYPE_PLAY = 16、NX_KEYTYPE_NEXT = 17、NX_KEYTYPE_PREVIOUS = 18。
    var keyType: Int {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .playPause: return 16
        case .nextTrack: return 17
        case .previousTrack: return 18
        }
    }
}

/// 无状态按键模拟器（KeyCombo 的 modifiers 存的是 CGEventFlags 的 rawValue）。
struct KeySimulator {

    // MARK: 权限

    /// 检查辅助功能权限。缺权限时抛 accessibilityDenied（不主动弹系统提示，
    /// 由调用方把错误文本展示给用户，引导其去系统设置开启）。
    func ensureAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw KeySimulatorError.accessibilityDenied
        }
    }

    // MARK: 普通组合键

    func keyDown(_ combo: KeyCombo) throws {
        try ensureAccessibility()
        // 关键：必须用 HID 系统状态事件源创建事件。默认源（nil）发出的合成事件
        // 只对普通 App 有效，Dock 的系统快捷键（如调度中心 ⌃←/⌃→ 切换空间、
        // ⌃↑ 调度中心）会直接忽略它——键盘按能生效、程序模拟按不生效就是这个原因。
        // HID 源发出的事件与真实键盘走同一通道，系统快捷键才会响应。
        // 另外按真实键盘的完整顺序发：先按修饰键（flagsChanged），再按主键。
        try postModifierFlagsChanged(combo: combo, down: true)
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: CGKeyCode(combo.keyCode),
            keyDown: true
        ) else {
            throw KeySimulatorError.eventCreationFailed
        }
        event.flags = Self.mainKeyFlags(combo)
        event.post(tap: .cghidEventTap)
    }

    func keyUp(_ combo: KeyCombo) throws {
        try ensureAccessibility()
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: CGKeyCode(combo.keyCode),
            keyDown: false
        ) else {
            throw KeySimulatorError.eventCreationFailed
        }
        event.flags = Self.mainKeyFlags(combo)
        event.post(tap: .cghidEventTap)
        // 真实键盘的松开顺序：先松主键，再松修饰键（flagsChanged）。
        try postModifierFlagsChanged(combo: combo, down: false)
    }

    /// 主键事件的 flags。真实键盘的方向键 / Home / End / 翻页 / 前向删除事件都自带
    /// maskSecondaryFn（0x800000）；系统快捷键（⌃←/→ 切换空间、⌃↑ 调度中心、⌃↓ 应用窗口）
    /// 匹配这些键时依赖该标志，缺了就被当成普通按键，前台 App 只会“噔”一声。
    private static let fnImpliedKeyCodes: Set<Int> = [123, 124, 125, 126, 115, 119, 116, 121, 117]

    private static func mainKeyFlags(_ combo: KeyCombo) -> CGEventFlags {
        var flags = CGEventFlags(rawValue: CGEventFlags.RawValue(combo.modifiers))
        if fnImpliedKeyCodes.contains(combo.keyCode) {
            flags.insert(.maskSecondaryFn)
        }
        return flags
    }

    /// 修饰键码（左侧版本；系统快捷键匹配只看 flags，左右无所谓）。
    private static let modifierKeyCodes: [(flag: Int, keyCode: Int)] = [
        (1 << 18, 59),  // Control
        (1 << 19, 58),  // Option
        (1 << 17, 56),  // Shift
        (1 << 20, 55),  // Command
    ]

    /// 按真实键盘的顺序发修饰键的 flagsChanged：按下时按 Control→Option→Shift→Command
    /// 累积 flags，松开时倒序逐个清除。无修饰的组合键、Fn 不走这里（Fn 有自己的 postFnEvent）。
    private func postModifierFlagsChanged(combo: KeyCombo, down: Bool) throws {
        let active = Self.modifierKeyCodes.filter { combo.modifiers & $0.flag != 0 }
        guard !active.isEmpty else { return }
        // 注意：Array 与 reversed() 类型不同，必须统一成 Array 才能写三元表达式。
        let ordered: [(flag: Int, keyCode: Int)] = down ? active : Array(active.reversed())
        var flags = down ? 0 : combo.modifiers
        for (flag, keyCode) in ordered {
            if down {
                flags |= flag
            } else {
                flags &= ~flag
            }
            guard let event = CGEvent(
                keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                virtualKey: CGKeyCode(keyCode),
                keyDown: down
            ) else {
                throw KeySimulatorError.eventCreationFailed
            }
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: CGEventFlags.RawValue(flags))
            event.post(tap: .cghidEventTap)
        }
    }

    /// 按一次：按下 + 松开（用于单击类动作与“点按式”语音工具）。
    func press(_ combo: KeyCombo) throws {
        try keyDown(combo)
        try keyUp(combo)
    }

    // MARK: 应用切换器会话（按住 ⌘ 不放）

    /// 开始切换器：按下并保持 ⌘，再按一次 Tab（弹出 ⌘Tab 切换器）。⌘ 一直保持到 switcherEnd。
    func switcherBegin() throws {
        try ensureAccessibility()
        try postCommandFlag(down: true)
        try postKeyWhileCommandHeld(keyCode: 48, extra: [])
    }

    /// 切换器内按一个键（方向键、Esc 等），⌘ 仍保持按下。
    func switcherKey(_ keyCode: Int, shift: Bool = false) throws {
        try ensureAccessibility()
        var extra: CGEventFlags = shift ? .maskShift : []
        if Self.fnImpliedKeyCodes.contains(keyCode) { extra.insert(.maskSecondaryFn) }
        try postKeyWhileCommandHeld(keyCode: keyCode, extra: extra)
    }

    /// 结束切换器：松开 ⌘，系统切到当前高亮的应用/窗口。
    func switcherEnd() throws {
        try ensureAccessibility()
        try postCommandFlag(down: false)
    }

    private func postCommandFlag(down: Bool) throws {
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: 55,
            keyDown: down
        ) else { throw KeySimulatorError.eventCreationFailed }
        event.type = .flagsChanged
        event.flags = down ? .maskCommand : []
        event.post(tap: .cghidEventTap)
    }

    private func postKeyWhileCommandHeld(keyCode: Int, extra: CGEventFlags) throws {
        for down in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                virtualKey: CGKeyCode(keyCode),
                keyDown: down
            ) else { throw KeySimulatorError.eventCreationFailed }
            event.flags = extra.union(.maskCommand)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: 语音热键（区分 Fn 与普通组合键）

    /// 语音会话开始：Fn 发 flagsChanged（按下），普通组合键发 keyDown。
    func hotkeyDown(_ combo: KeyCombo) throws {
        if combo.isFn {
            try postFnEvent(down: true)
        } else {
            try keyDown(combo)
        }
    }

    /// 语音会话结束：Fn 发 flagsChanged（松开），普通组合键发 keyUp。
    func hotkeyUp(_ combo: KeyCombo) throws {
        if combo.isFn {
            try postFnEvent(down: false)
        } else {
            try keyUp(combo)
        }
    }

    /// Fn 键模拟：flagsChanged 事件，keyCode 63；按下带 maskSecondaryFn，松开不带。
    /// 注意：不能用普通 keyDown/keyUp 模拟 Fn，系统只认 flagsChanged。
    private func postFnEvent(down: Bool) throws {
        try ensureAccessibility()
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 63,
            keyDown: down
        ) else {
            throw KeySimulatorError.eventCreationFailed
        }
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        event.post(tap: .cghidEventTap)
    }

    // MARK: 系统媒体键（音量/静音）

    /// 通过 NSEvent systemDefined（subtype 8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS）
    /// 转 CGEvent 投递；按下与松开各发一次（data1 高 16 位为 keyType，
    /// 0x0A00 = 按下、0x0B00 = 松开）。
    func mediaKey(_ key: MediaKey) throws {
        try ensureAccessibility()
        try postMediaKeyEvent(key, down: true)
        try postMediaKeyEvent(key, down: false)
    }

    private func postMediaKeyEvent(_ key: MediaKey, down: Bool) throws {
        let data1 = (key.keyType << 16) | (down ? 0x0A00 : 0x0B00)
        // otherEvent 的返回空值性在不同 SDK 间有差异，先包成可选再解包，两边都可编译。
        guard let cgEvent = (NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) as NSEvent?)?.cgEvent else {
            throw KeySimulatorError.eventCreationFailed
        }
        cgEvent.post(tap: .cghidEventTap)
    }
}
