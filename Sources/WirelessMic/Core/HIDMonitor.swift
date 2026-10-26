// HIDMonitor.swift
// Chromecast 语音遥控器（G9N9N）的 HID 按键监听：IOKit HID Manager。
// 只负责普通按键（方向、确认、返回、音量等）的按下/抬起边沿。
// 注意：语音键不走 HID（走 ATVV 控制通道），不要用 HID 判断语音。
// 线程约定：HID Manager 挂在主 RunLoop，所有回调都在主线程。

import Foundation
import IOKit

/// 按键边沿（MappingEngine 的输入）。
enum ButtonPhase {
    case down
    case up
}

/// HID 原始事件：usage page、usage、数值。全部上报，供真机联调修正映射表。
final class HIDMonitor {

    /// 映射到的按键 + 边沿。
    var onButtonEvent: ((RemoteButton, ButtonPhase) -> Void)?
    /// 原始 usage 事件（page、usage、value），无论是否在映射表内都上报。
    var onRawUsage: ((Int, Int, Int) -> Void)?
    var onLog: ((String) -> Void)?

    /// G9N9N 在 macOS 蓝牙 HID 下的 VID/PID（社区 Win 版设备档案值）。
    private static let vendorID = 6353
    private static let productID = 37968

    /// usage page 常量。
    private static let pageGenericDesktop = 0x01
    private static let pageKeyboard = 0x07
    private static let pageConsumer = 0x0C
    private static let usageHatSwitch = 0x39

    /// usage → 按键对照表。
    ///
    /// 已确认的用法（标准 HID 用法表）：
    /// - 键盘页 0x07：0x52 上、0x51 下、0x50 左、0x4F 右、0x28 回车（确认）、0x29 ESC（返回）
    /// - 消费页 0x0C：0xE9 音量+、0xEA 音量-、0xE2 静音
    /// - 通用桌面页 0x01 十字开关 0x39：0 上、2 右、4 下、6 左（8 或更大值 = 回中）
    ///
    /// G9N9N 实测（2026-10-26 用户日志，消费页 0x0C）：
    /// - 方向盘是菜单键：0x42 上、0x43 下、0x44 左、0x45 右
    /// - 0x224 AC Back = 返回键
    /// - 同一次按键还会伴随一条 usage 0xFFFFFFFF 的原始事件（厂商编码，不映射，只记日志）
    ///
    /// 候选（HID 标准用法，待日志确认；已接进表里，日志会验证）：
    /// - 0x41 菜单选择 = 确认、0xCD 播放/暂停 = 确认（若确认键同时发 0x41 与 0xCD，
    ///   下面的按键级去重会合并成一次，不会变双击）
    /// - 0x223 AC Home = 主页、0x30 电源 = 电源
    /// - 0x19E（AL Terminal Lock，2026-10-26 日志实测）= 遥控器电源键，系统默认响应为锁屏
    /// - YouTube、Netflix、输入源：厂商自定义用法未知，不猜，等日志再补。
    private static let keyTable: [Int: [Int: RemoteButton]] = [
        pageKeyboard: [
            0x52: .up,
            0x51: .down,
            0x50: .left,
            0x4F: .right,
            0x28: .select,
            0x29: .back,
        ],
        pageConsumer: [
            0xE9: .volumeUp,
            0xEA: .volumeDown,
            0xE2: .mute,
            0x42: .up,
            0x43: .down,
            0x44: .left,
            0x45: .right,
            0x224: .back,
            0x41: .select,
            0xCD: .select,
            0x223: .home,
            0x30: .power,
            0x19E: .power,
        ],
    ]

    /// 十字开关方向值 → 按键（仅 0/2/4/6 四个正方向；斜向不映射，只记日志）。
    private static let hatTable: [Int: RemoteButton] = [
        0: .up,
        2: .right,
        4: .down,
        6: .left,
    ]

    private var manager: IOHIDManager?
    private var running = false
    /// Manager 层是否已独占打开（是则设备已被独占，不必再逐台打开）。
    private var managerSeized = false
    /// 已独占打开的设备（seize 成功后系统不再收到该设备的按键）。
    private var devices: [IOHIDDevice] = []
    /// 当前按下的普通键（按按键聚合）：同一颗键若同时发两种用法（如确认键发 0x41 与 0xCD），
    /// 只算一次按下/抬起，避免双编码变成双击。
    private var pressedButtonKeys: [RemoteButton: Set<String>] = [:]
    /// 当前十字开关方向（nil = 回中）。
    private var currentHatDirection: RemoteButton?

    // MARK: 公开方法

    func start() {
        guard !running else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged<HIDMonitor>.passUnretained(self).toOpaque()
        // 注意：不要在 Manager 层注册输入回调（Manager 回调是共享观察，系统仍会收到按键）。
        // 改为设备层回调 + 独占打开（seize）：独占后系统不再收到该遥控器的按键，
        // 才能拦住原生行为（确认键弹 Apple Music、电源键锁屏、静音键被系统再切一次）。
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.log("HID 设备已接入（VID 6353 / PID 37968）")
            monitor.openDevice(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context = context else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.log("HID 设备已移除")
            monitor.closeDevices()
        }, context)

        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        // 先在 Manager 层独占打开（对所有匹配设备生效）：loginwindow 对电源键（消费页 0x19E）
        // 的锁屏响应，设备层独占拦不住（日志实测：独占已建立但仍锁屏）。
        var result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result == kIOReturnSuccess {
            managerSeized = true
            log("HID Manager 层独占已建立")
        } else {
            log("HID Manager 层独占失败（IOReturn=\(result)），改用共享打开")
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            log("HID Manager 打开失败：IOReturn=\(result)")
            return
        }
        running = true
        log("HID 监听已启动（VID 6353 / PID 37968）")
    }

    func stop() {
        guard running, let manager = manager else { return }
        running = false
        closeDevices()
        IOHIDManagerUnscheduleFromRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        managerSeized = false
        log("HID 监听已停止")
    }

    /// 独占打开一台设备并挂上输入回调。独占失败时回落共享模式并明说
    /// （共享模式下系统仍会响应遥控器按键，上述原生行为拦不住）。
    private func openDevice(_ device: IOHIDDevice) {
        var result = managerSeized
            ? kIOReturnSuccess
            : IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        var seized = true
        if result != kIOReturnSuccess {
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            seized = false
        }
        guard result == kIOReturnSuccess else {
            log("HID 设备打开失败：IOReturn=\(result)")
            return
        }
        if seized {
            log("HID 独占已建立（系统不再响应遥控器按键）")
        } else {
            log("HID 独占失败，已回落共享模式（系统仍会响应遥控器按键：可能弹 Apple Music、锁屏、静音反复；请确认已授予输入监控权限后重启应用）")
        }
        let context = Unmanaged<HIDMonitor>.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context = context else { return }
            let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleValue(value)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        devices.append(device)
    }

    /// 关闭全部已打开的设备（退出监听、设备移除时调用；关闭后系统恢复响应遥控器）。
    private func closeDevices() {
        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(
                device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        devices.removeAll()
        pressedButtonKeys.removeAll()
        currentHatDirection = nil
    }

    // MARK: 事件处理

    private func log(_ message: String) {
        onLog?(message)
    }

    private func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let intValue = Int(IOHIDValueGetIntegerValue(value))
        onRawUsage?(page, usage, intValue)

        if page == Self.pageGenericDesktop, usage == Self.usageHatSwitch {
            handleHat(value: intValue)
            return
        }
        guard let button = Self.keyTable[page]?[usage] else {
            // 不在映射表内：只记原始日志，不产生按键事件，等真机联调补表。
            return
        }
        // 按按键聚合去重：同一颗键同时发两种用法时，只算一次按下/抬起。
        let key = "\(page):\(usage)"
        var keys = pressedButtonKeys[button] ?? []
        if intValue != 0 {
            let wasEmpty = keys.isEmpty
            keys.insert(key)
            pressedButtonKeys[button] = keys
            if wasEmpty {
                onButtonEvent?(button, .down)
            }
        } else {
            keys.remove(key)
            if keys.isEmpty {
                pressedButtonKeys.removeValue(forKey: button)
                onButtonEvent?(button, .up)
            } else {
                pressedButtonKeys[button] = keys
            }
        }
    }

    /// 十字开关：0/2/4/6 为方向，8 或更大值为回中；方向变化时先抬起旧方向再按下新方向。
    private func handleHat(value: Int) {
        let direction = Self.hatTable[value]
        guard direction != currentHatDirection else { return }
        if let old = currentHatDirection {
            onButtonEvent?(old, .up)
        }
        currentHatDirection = direction
        if let direction = direction {
            onButtonEvent?(direction, .down)
        } else if value != 8 {
            // 非标准回中值也记一笔，方便联调时确认该遥控器的回中编码。
            log("HID 十字开关回中（原始值 \(value)，已按回中处理）")
        }
    }
}
