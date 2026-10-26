// MicEngine.swift
// 外观：UI 只依赖它。串联 ATVVEngine（BLE 语音）、HIDMonitor（按键）、
// AudioPipeline（输出到 BlackHole）、MappingEngine（按键动作）、SettingsStore（持久化）。
// 语音会话开关只有一套：startVoice/stopVoice；遥控器话筒键与宿主侧 setVoiceActive
// 共用它，内部守卫保证不重复 openMic、不重复按 Fn、不重复 closeMic。
// 所有 @Published 更新都在主线程（ATVV/HID 回调本身就在主线程）。

import Foundation
import Combine

final class MicEngine: ObservableObject {

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isVoiceActive = false
    @Published private(set) var level: Float = 0
    @Published private(set) var logLines: [String] = []
    /// 最近按下的遥控器按键（仅 down 边沿）：按键页“检测真实按键”用它高亮卡片。
    @Published private(set) var lastPressedButton: RemoteButton?
    @Published var settings: AppSettings

    private let atvv: ATVVEngine
    private let hid: HIDMonitor
    private let audio: AudioPipeline
    private let mapping: MappingEngine
    private let keySimulator: KeySimulator
    private let settingsStore: SettingsStore

    private static let logCap = 200
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init() {
        let store = SettingsStore()
        let loaded = store.load()
        settingsStore = store
        settings = loaded
        keySimulator = KeySimulator()
        mapping = MappingEngine(mappings: loaded.mappings, keySimulator: keySimulator)
        atvv = ATVVEngine()
        hid = HIDMonitor()
        audio = AudioPipeline(deviceName: loaded.outputDeviceName)

        audio.onError = { [weak self] message in self?.appendLog(message) }

        atvv.onConnection = { [weak self] state in
            guard let self = self else { return }
            self.connectionState = state
            self.appendLog("连接状态：\(state.displayName)")
            // 断线时若语音还开着，立刻收尾：松开热键、关话筒、停音频，避免 Fn 卡住。
            if case .disconnected = state {
                self.stopVoiceIfNeededOnDisconnect()
            } else if case .failed = state {
                self.stopVoiceIfNeededOnDisconnect()
            }
        }
        atvv.onVoiceButtonDown = { [weak self] in self?.voiceButtonDown() }
        atvv.onVoiceButtonUp = { [weak self] in self?.voiceButtonUp() }
        atvv.onSamples = { [weak self] samples in
            guard let self = self, self.isVoiceActive else { return }
            self.audio.push(samples)
            self.updateLevel(from: samples)
        }
        atvv.onLog = { [weak self] message in self?.appendLog(message) }

        hid.onButtonEvent = { [weak self] button, phase in
            if phase == .down {
                self?.lastPressedButton = button
            }
            self?.mapping.handleEdge(button: button, phase: phase)
        }
        hid.onRawUsage = { [weak self] page, usage, value in
            self?.appendLog(String(format: "HID 原始：page 0x%02X usage 0x%02X value %d", page, usage, value))
        }
        hid.onLog = { [weak self] message in self?.appendLog(message) }

        mapping.onActionExecuted = { [weak self] button, press, action in
            self?.appendLog("动作：\(button.displayName) \(press.displayName) → \(action.displayName)")
        }
        mapping.onMappingsChanged = { [weak self] newMappings in
            guard let self = self else { return }
            self.settings.mappings = newMappings
            self.persistSettings()
        }
        mapping.onError = { [weak self] message in self?.appendLog(message) }
    }

    // MARK: 公开方法

    /// 清空诊断日志（设备页“清空”按钮用）。
    func clearLog() {
        logLines.removeAll()
    }

    func start() {
        appendLog("无线麦版本：\(BuildVersion.string)")
        appendLog("启动：开始搜索 Chromecast 遥控器…")
        atvv.start()
        hid.start()
    }

    func stop() {
        stopVoice()
        atvv.stop()
        mapping.shutdown()
        hid.stop()
        appendLog("已停止")
    }

    func reconnect() {
        atvv.reconnect()
    }

    /// 宿主侧手动开关语音（界面菜单用），不依赖遥控器话筒键。
    /// 与遥控器话筒键共用 startVoice/stopVoice：已开时再开是空操作，
    /// 已关时再关也是空操作，不会重复 openMic、不会重复按 Fn。
    func setVoiceActive(_ active: Bool) {
        if active {
            startVoice()
        } else {
            stopVoice()
        }
    }

    func setVoiceMode(_ mode: VoiceMode) {
        settings.voiceMode = mode
        persistSettings()
    }

    func setTool(_ tool: VoiceTool) {
        settings.selectedTool = tool
        persistSettings()
    }

    /// 改映射：经 MappingEngine 落表，onMappingsChanged 回调再同步 settings 并持久化。
    func setMapping(button: RemoteButton, press: PressKind, action: ButtonAction) {
        mapping.setMapping(button: button, press: press, action: action)
    }

    /// 保存当前映射为预设（同名覆盖），并持久化。
    func savePreset(name: String) {
        settings.presets[name] = settings.mappings
        persistSettings()
        appendLog("已保存按键配置预设“\(name)”")
    }

    /// 应用预设：整套替换当前映射并持久化。
    func applyPreset(name: String) {
        guard let preset = settings.presets[name] else { return }
        mapping.replaceMappings(preset)
        appendLog("已应用按键配置预设“\(name)”")
    }

    /// 删除预设，并持久化。
    func deletePreset(name: String) {
        settings.presets.removeValue(forKey: name)
        persistSettings()
        appendLog("已删除按键配置预设“\(name)”")
    }

    /// 改输出设备并持久化。语音进行中时在新设备上重启管线，重启失败则结束语音会话。
    func setOutputDevice(_ name: String) {
        settings.outputDeviceName = name
        persistSettings()
        if isVoiceActive {
            do {
                try audio.setDevice(name)
                appendLog("输出设备已切换为“\(name)”")
            } catch {
                appendLog("切换输出设备失败：\(error.localizedDescription)，结束语音会话")
                stopVoice()
            }
        } else {
            audio.deviceName = name
        }
    }

    // MARK: 遥控器话筒键 → 语音意图

    private func voiceButtonDown() {
        switch settings.voiceMode {
        case .hold:
            startVoice()
        case .toggle:
            if isVoiceActive {
                stopVoice()
            } else {
                startVoice()
            }
        }
    }

    private func voiceButtonUp() {
        switch settings.voiceMode {
        case .hold:
            stopVoice()
        case .toggle:
            // 点按切换模式下松开不结束会话：up 来自 AUDIO_STOP（音频流结束），
            // 每次松开话筒键都会发一次；若这里 stop，一次点按的松开就会立刻
            // 结束会话，toggle 会退化成 hold。切换只由按下（voiceButtonDown）触发。
            break
        }
    }

    // MARK: 语音会话开关（唯一入口，startVoice/stopVoice 互斥守卫）

    /// 开始语音：失败闭合——音频启动失败则在 openMic 之前记日志返回；
    /// 热键发送失败则回滚（closeMic、停音频、清状态），不留半开会话。
    private func startVoice() {
        guard !isVoiceActive else { return }
        guard case .connected = connectionState else {
            appendLog("未连接遥控器，无法开始语音")
            return
        }
        do {
            try audio.start()
        } catch {
            appendLog("语音启动失败：\(error.localizedDescription)")
            return
        }
        atvv.openMic()
        isVoiceActive = true
        do {
            try keySimulator.hotkeyDown(currentHotkey())
        } catch {
            atvv.closeMic()
            audio.stop()
            isVoiceActive = false
            appendLog("语音热键发送失败：\(error.localizedDescription)")
            return
        }
        appendLog("语音已开始（工具：\(settings.selectedTool.displayName)，热键：\(currentHotkey().display)）")
    }

    /// 结束语音：幂等——已关时直接返回；顺序为 Fn 松开、closeMic、停音频、电平归零。
    private func stopVoice() {
        guard isVoiceActive else { return }
        isVoiceActive = false
        level = 0
        do {
            try keySimulator.hotkeyUp(currentHotkey())
        } catch {
            appendLog("语音热键松开失败：\(error.localizedDescription)")
        }
        atvv.closeMic()
        audio.stop()
        appendLog("语音已结束")
    }

    /// 断线收尾：仅当语音正开着时调用 stopVoice（防 Fn 卡住）。
    private func stopVoiceIfNeededOnDisconnect() {
        guard isVoiceActive else { return }
        appendLog("连接已断开，结束进行中的语音会话")
        stopVoice()
    }

    // MARK: 辅助

    /// 当前所选工具的热键（未配置时默认 Fn）。
    private func currentHotkey() -> KeyCombo {
        settings.toolHotkeys[settings.selectedTool.rawValue] ?? .fn
    }

    /// 电平：PCM RMS / 12000 归一化到 0…1，0.65/0.35 平滑；非语音时为 0。
    private func updateLevel(from samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var sum: Double = 0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        let rms = sqrt(sum / Double(samples.count))
        let target = Float(min(1, rms / 12000))
        level = level * 0.65 + target * 0.35
    }

    private func persistSettings() {
        do {
            try settingsStore.save(settings)
        } catch {
            appendLog("保存设置失败：\(error.localizedDescription)")
        }
    }

    private func appendLog(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(message)")
        if logLines.count > Self.logCap {
            logLines.removeFirst(logLines.count - Self.logCap)
        }
        Self.appendToLogFile("[\(stamp)] \(message)\n")
    }

    /// 同步写一份日志到 ~/Library/Application Support/WirelessMic/app.log，
    /// 便于不开界面也能查看原始 HID 事件。超过 2MB 时从头截断。
    private static let logFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WirelessMic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private static func appendToLogFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(at: logFileURL)
        }
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
