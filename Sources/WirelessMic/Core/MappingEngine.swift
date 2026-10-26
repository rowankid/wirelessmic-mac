// MappingEngine.swift
// 按键边沿 → 单击/双击/长按判定 → 查映射表执行动作。
// 时序（对齐 SayAll Mac 版公开文档的模型）：
// - 双击、长按都未设置时：单击即时响应（按下即执行），按住重复（无修饰普通键、音量±；
//   带修饰的组合键与静音开关只发一次，避免开关类动作反复触发）。
// - 只设置长按时：按住 0.55 秒执行长按并抑制单击；提前抬起则抬起即执行单击（不等窗口）。
// - 设置双击时：抬起后等 0.3 秒窗口区分单击/双击；设置了双击或长按的键不再按住重复。
// 执行：key 走 KeySimulator，volumeUp/volumeDown/muteToggle/playPause/nextTrack/previousTrack 走系统媒体键。
// 线程约定：HID 回调在主线程，全部定时器都用主队列。

import Foundation

final class MappingEngine {

    /// 双击窗口：第一次抬起后这么久内再按下，算双击（仅设置了双击时用）。
    static let doubleClickWindow: TimeInterval = 0.30
    /// 长按阈值：按住这么久未抬起，算长按（长按触发后不再补发单击/双击）。
    static let longPressThreshold: TimeInterval = 0.55
    /// 按住重复：首次重复前的延迟（仅即时模式）。
    static let repeatInitialDelay: TimeInterval = 0.40
    /// 按住重复：重复间隔（仅即时模式）。
    static let repeatInterval: TimeInterval = 0.10

    /// 动作执行后回调（供 MicEngine 记日志），参数：按键、方式、执行的动作。
    var onActionExecuted: ((RemoteButton, PressKind, ButtonAction) -> Void)?
    /// 映射表变化后回调（供 MicEngine 同步 settings 并持久化）。
    var onMappingsChanged: (([String: ButtonAction]) -> Void)?
    /// 执行期错误（如辅助功能权限缺失），供 MicEngine 记入日志。
    var onError: ((String) -> Void)?

    private let keySimulator: KeySimulator
    private(set) var mappings: [String: ButtonAction]

    /// 单颗按键的判定状态。
    private struct ButtonState {
        /// 当前是否按住（downTime 非空即按住）。
        var downTime: Date?
        /// 待确认的单击（第一次抬起后 0.3 秒内未再按下才真正执行；仅设置了双击时用）。
        var pendingSingle: DispatchWorkItem?
        /// 长按定时器（按下后 0.55 秒未抬起即触发）。
        var longWork: DispatchWorkItem?
        /// 按住重复定时器（仅即时模式：双击、长按都未设置时）。
        var repeatWork: DispatchWorkItem?
        /// 本轮是否已触发长按（触发后抬起不再补发单击/双击）。
        var longFired = false
        /// 本轮第二次按下是否落在双击窗口内（是则抬起时执行双击）。
        var doubleCandidate = false
        /// 即时模式下单击是否已在按下时执行过（是则抬起不再补发）。
        var instantFired = false
    }

    private var states: [RemoteButton: ButtonState] = [:]

    init(mappings: [String: ButtonAction], keySimulator: KeySimulator = KeySimulator()) {
        self.mappings = mappings
        self.keySimulator = keySimulator
    }

    // MARK: 公开方法

    /// 处理一颗按键的边沿（HIDMonitor 回调入口）。
    func handleEdge(button: RemoteButton, phase: ButtonPhase) {
        if switcherActive {
            handleSwitcherEdge(button: button, phase: phase)
            return
        }
        switch phase {
        case .down:
            handleDown(button: button)
        case .up:
            handleUp(button: button)
        }
    }

    /// 修改一颗按键在某种方式下的动作，并通知调用方持久化。
    func setMapping(button: RemoteButton, press: PressKind, action: ButtonAction) {
        mappings[AppSettings.mappingKey(button: button, press: press)] = action
        onMappingsChanged?(mappings)
    }

    /// 整套替换映射（预设应用时用）：一次回调，避免逐条写盘。
    func replaceMappings(_ newMappings: [String: ButtonAction]) {
        mappings = newMappings
        onMappingsChanged?(mappings)
    }

    /// 查某按键某方式的动作（无映射时返回 .none，不执行）。
    func action(for button: RemoteButton, press: PressKind) -> ButtonAction {
        mappings[AppSettings.mappingKey(button: button, press: press)] ?? .none
    }

    // MARK: 判定

    private func handleDown(button: RemoteButton) {
        var state = states[button] ?? ButtonState()
        let doubleSet = action(for: button, press: .double) != .none
        let longSet = action(for: button, press: .long) != .none
        if !doubleSet && !longSet {
            // 即时模式：未设置双击/长按时，单击按下即执行、按住重复（SayAll 同款模型）。
            state.pendingSingle?.cancel()
            state.pendingSingle = nil
            state.longWork?.cancel()
            state.longWork = nil
            state.repeatWork?.cancel()
            state.repeatWork = nil
            state.downTime = Date()
            state.longFired = false
            state.doubleCandidate = false
            state.instantFired = true
            states[button] = state
            execute(button: button, press: .single)
            scheduleRepeat(button: button, delay: Self.repeatInitialDelay)
            return
        }
        if state.pendingSingle != nil {
            // 第一次抬起后 0.3 秒内又按下：取消待确认的单击，走双击候选。
            state.pendingSingle?.cancel()
            state.pendingSingle = nil
            state.doubleCandidate = true
        } else {
            state.doubleCandidate = false
        }
        state.downTime = Date()
        state.longFired = false
        state.instantFired = false
        state.longWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var current = self.states[button] ?? ButtonState()
            // 仍按住且未触发过：长按胜出，取消双击候选。
            guard current.downTime != nil, !current.longFired else { return }
            current.longFired = true
            current.doubleCandidate = false
            current.pendingSingle?.cancel()
            current.pendingSingle = nil
            self.states[button] = current
            self.execute(button: button, press: .long)
        }
        state.longWork = work
        states[button] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressThreshold, execute: work)
    }

    /// 按住重复（仅即时模式）：可重复动作按住后先等 repeatInitialDelay，再每 repeatInterval 发一次；
    /// 抬起时取消。带修饰的组合键（⌃↑、⌃空格等开关类）与静音开关不重复，只发一次。
    private func scheduleRepeat(button: RemoteButton, delay: TimeInterval) {
        guard isRepeatable(action(for: button, press: .single)) else { return }
        var state = states[button] ?? ButtonState()
        state.repeatWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var current = self.states[button] ?? ButtonState()
            // 仍按住才重复；已抬起则停。
            guard current.downTime != nil else { return }
            current.repeatWork = nil
            self.states[button] = current
            self.execute(button: button, press: .single)
            self.scheduleRepeat(button: button, delay: Self.repeatInterval)
        }
        state.repeatWork = work
        states[button] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 是否可按住重复：无修饰的普通键（如方向键、回车、退格）与音量±可以；
    /// 带修饰的组合键、Fn、静音开关、未设置动作不可以。
    private func isRepeatable(_ action: ButtonAction) -> Bool {
        switch action {
        case .key(let combo):
            return combo.modifiers == 0 && !combo.isFn
        case .volumeUp, .volumeDown:
            return true
        case .muteToggle, .playPause, .nextTrack, .previousTrack, .none:
            return false
        }
    }

    private func handleUp(button: RemoteButton) {
        var state = states[button] ?? ButtonState()
        state.longWork?.cancel()
        state.longWork = nil
        state.repeatWork?.cancel()
        state.repeatWork = nil
        state.downTime = nil
        if state.longFired {
            // 本轮已触发长按：抬起不再补发任何动作。
            state.longFired = false
            state.doubleCandidate = false
            state.instantFired = false
            states[button] = state
            return
        }
        if state.doubleCandidate {
            state.doubleCandidate = false
            state.instantFired = false
            states[button] = state
            execute(button: button, press: .double)
            return
        }
        if state.instantFired {
            // 即时模式：单击已在按下时执行过，抬起不再补发。
            state.instantFired = false
            states[button] = state
            return
        }
        if action(for: button, press: .double) == .none {
            // 未设置双击：无需等窗口区分，抬起即执行单击（长按未触发时）。
            states[button] = state
            execute(button: button, press: .single)
            return
        }
        // 设置了双击：先挂起，0.3 秒内无第二次按下才真正执行单击。
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var current = self.states[button] ?? ButtonState()
            current.pendingSingle = nil
            self.states[button] = current
            self.execute(button: button, press: .single)
        }
        state.pendingSingle = work
        states[button] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleClickWindow, execute: work)
    }

    // MARK: 应用切换器会话（⌘Tab 完整版）

    /// 切换器空闲多久自动确认（防止 ⌘ 卡住不松）。
    static let switcherIdleTimeout: TimeInterval = 8.0

    private var switcherActive = false
    private var switcherTimeout: DispatchWorkItem?

    /// 映射到 ⌘Tab 的动作会进入“切换器会话”：⌘ 保持按下，期间遥控器按键被接管——
    /// 左/右 = 选上一个/下一个，上/下 = 方向键（下可展开该 App 的窗口），
    /// 确定 = 松开 ⌘ 确认切换，返回/电源 = Esc 取消并松开 ⌘。
    private func beginSwitcher() throws {
        try keySimulator.switcherBegin()
        switcherActive = true
        // 进入时清掉所有按键的待决状态，避免残留定时器在会话中触发。
        for (button, var state) in states {
            state.pendingSingle?.cancel(); state.pendingSingle = nil
            state.longWork?.cancel(); state.longWork = nil
            state.repeatWork?.cancel(); state.repeatWork = nil
            state.downTime = nil
            states[button] = state
        }
        resetSwitcherTimeout()
    }

    private func resetSwitcherTimeout() {
        switcherTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endSwitcher(cancel: false) }
        switcherTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switcherIdleTimeout, execute: work)
    }

    private func endSwitcher(cancel: Bool) {
        guard switcherActive else { return }
        switcherActive = false
        switcherTimeout?.cancel()
        switcherTimeout = nil
        do {
            if cancel { try keySimulator.switcherKey(53) }
            try keySimulator.switcherEnd()
        } catch {
            onError?("结束切换器失败：\(error.localizedDescription)")
        }
    }

    /// 应用退出时调用，确保 ⌘ 被松开。
    func shutdown() {
        endSwitcher(cancel: true)
    }

    private func handleSwitcherEdge(button: RemoteButton, phase: ButtonPhase) {
        guard phase == .down else { return }
        resetSwitcherTimeout()
        do {
            switch button {
            case .left: try keySimulator.switcherKey(123)
            case .right: try keySimulator.switcherKey(124)
            case .up: try keySimulator.switcherKey(126)
            case .down: try keySimulator.switcherKey(125)
            case .select, .home:
                endSwitcher(cancel: false)
            case .back, .power:
                endSwitcher(cancel: true)
            default:
                break
            }
        } catch {
            onError?("切换器按键失败：\(error.localizedDescription)")
            endSwitcher(cancel: true)
        }
    }

    // MARK: 执行

    private func execute(button: RemoteButton, press: PressKind) {
        let action = action(for: button, press: press)
        guard action != .none else { return }
        do {
            switch action {
            case .none:
                return
            case .key(let combo):
                if combo == .appSwitcher {
                    try beginSwitcher()
                } else {
                    try keySimulator.press(combo)
                }
            case .volumeUp:
                try keySimulator.mediaKey(.volumeUp)
            case .volumeDown:
                try keySimulator.mediaKey(.volumeDown)
            case .muteToggle:
                try keySimulator.mediaKey(.mute)
            case .playPause:
                try keySimulator.mediaKey(.playPause)
            case .nextTrack:
                try keySimulator.mediaKey(.nextTrack)
            case .previousTrack:
                try keySimulator.mediaKey(.previousTrack)
            }
            onActionExecuted?(button, press, action)
        } catch {
            onError?("执行动作失败（\(button.displayName) \(press.displayName)）：\(error.localizedDescription)")
        }
    }
}
