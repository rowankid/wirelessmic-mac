// ATVVEngine.swift
// Chromecast 语音遥控器（G9N9N）的 BLE ATVV 引擎：连接、握手、语音会话、音频解码。
// 协议来源：社区 Win 版 ZSTDJan/windows-remote-mic-app 公开的 ATVV 实现
// （atvv_protocol.py / atvv_session.py）+ Google Voice over BLE spec v1.0，
// 握手与解码逻辑与已验证的 chromecast-v0.swift 一致，改成流式输出（不写文件）。
// 线程约定：CBCentralManager 用主队列创建，所有回调都在主线程，MicEngine 可直接更新 @Published。

import Foundation
import CoreBluetooth

// MARK: - ATVV 常量

/// ATVV 语音服务与特征值（Google Voice over BLE spec v1.0）。
private enum ATVV {
    static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    static let tx = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    static let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    static let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")

    /// 控制通道操作码（CTL 通知的首字节）。
    static let opcodeAudioStop: UInt8 = 0x00
    static let opcodeAudioStart: UInt8 = 0x04
    static let opcodeMicButton: UInt8 = 0x08
    static let opcodeAudioSync: UInt8 = 0x0A
    static let opcodeCaps: UInt8 = 0x0B

    /// v1.0 能力查询命令（写 TX 特征值）。
    static let getCapabilitiesV10: [UInt8] = [0x0A, 0x01, 0x00, 0x00, 0x03, 0x03]
    static let defaultFrameSize = 120
    static let supportedSampleRate = 16000
    /// AUDIO_STOP 后这段时间内到达的音频视为上一会话残留，直接丢弃。
    static let lateAudioGuardSeconds = 0.3

    static func micOpenCommand(version: UInt16) -> [UInt8] {
        version >= 0x0100 ? [0x0C, 0x00] : [0x0C, 0x00, 0x00]
    }

    static func micCloseCommand(version: UInt16, sessionID: UInt8) -> [UInt8] {
        version >= 0x0100 ? [0x0D, sessionID] : [0x0D]
    }
}

// MARK: - IMA/DVI ADPCM 解码（标准表，高 nibble 在前）

/// 标准 IMA/DVI 4-bit ADPCM 解码器，每字节出 2 个采样。
private final class IMAADPCMDecoder {
    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
        143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
        494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
        1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8]

    private var predictor = 0
    private var stepIndex = 0

    func reset(predictor: Int = 0, stepIndex: Int = 0) {
        self.predictor = min(32767, max(-32768, predictor))
        self.stepIndex = min(88, max(0, stepIndex))
    }

    func decode(_ data: [UInt8]) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(data.count * 2)
        for byte in data {
            samples.append(decodeNibble(Int(byte >> 4)))
            samples.append(decodeNibble(Int(byte & 0x0F)))
        }
        return samples
    }

    private func decodeNibble(_ nibble: Int) -> Int16 {
        let step = Self.stepTable[stepIndex]
        var difference = step >> 3
        if nibble & 1 != 0 { difference += step >> 2 }
        if nibble & 2 != 0 { difference += step >> 1 }
        if nibble & 4 != 0 { difference += step }
        if nibble & 8 != 0 {
            predictor -= difference
        } else {
            predictor += difference
        }
        predictor = min(32767, max(-32768, predictor))
        stepIndex += Self.indexTable[nibble & 7]
        stepIndex = min(88, max(0, stepIndex))
        return Int16(predictor)
    }
}

// MARK: - 直流高通滤波（去 ADPCM 预测器偏置，20 Hz 截止）

private final class DCHighPassFilter {
    private let alpha: Double
    private var prevIn = 0.0
    private var prevOut = 0.0
    private var initialized = false

    init(sampleRate: Double = 16000, cutoffHz: Double = 20) {
        alpha = exp(-2.0 * Double.pi * cutoffHz / sampleRate)
    }

    func reset() {
        prevIn = 0.0
        prevOut = 0.0
        initialized = false
    }

    func process(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        if !initialized {
            prevIn = Double(samples[0])
            initialized = true
        }
        var out: [Int16] = []
        out.reserveCapacity(samples.count)
        for sample in samples {
            let current = Double(sample)
            let value = current - prevIn + alpha * prevOut
            prevIn = current
            prevOut = value
            out.append(Int16(min(32767, max(-32768, Int(round(value))))))
        }
        return out
    }
}

// MARK: - 后处理：三抽头平滑 + 10 dB 增益

private func atvvPostprocess(_ samples: [Int16], gainDb: Double = 10.0) -> [Int16] {
    guard !samples.isEmpty else { return [] }
    var filtered = samples
    if samples.count >= 3 {
        for i in 1..<(samples.count - 1) {
            filtered[i] = Int16((Int(samples[i - 1]) + 2 * Int(samples[i]) + Int(samples[i + 1])) >> 2)
        }
    }
    let safeGainDb = min(24.0, max(-24.0, gainDb))
    let gain = pow(10.0, safeGainDb / 20.0)
    return filtered.map { Int16(min(32767, max(-32768, Int(round(Double($0) * gain)))) ) }
}

// MARK: - 帧重组：把任意切分的蓝牙通知拼回固定帧

private final class FrameAccumulator {
    private var pending: [UInt8] = []

    func append(_ data: [UInt8], frameSize: Int) -> [[UInt8]] {
        guard frameSize > 0 else { return [] }
        pending.append(contentsOf: data)
        var frames: [[UInt8]] = []
        while pending.count >= frameSize {
            frames.append(Array(pending.prefix(frameSize)))
            pending.removeFirst(frameSize)
        }
        return frames
    }

    func reset() { pending.removeAll() }
}

// MARK: - ATVV 会话状态机（单次连接内有效，断线重连时重建）

private struct ATVVCapabilities {
    let version: UInt16
    let codecs: Int
    let interaction: Int
    let frameSize: Int
    let selectedCodec: Int
    let sampleRate: Int
}

private final class ATVVSession {
    var version: UInt16 = 0
    var caps: ATVVCapabilities?
    var frameSize = ATVV.defaultFrameSize
    var micOpen = false
    var lastMicOffAt: Date?
    var lastSessionID: UInt8 = 0

    private let decoder = IMAADPCMDecoder()
    private let dcFilter = DCHighPassFilter()
    private let accumulator = FrameAccumulator()
    private var pendingSync: (predictor: Int, stepIndex: Int)?

    /// 解析 CAPS 帧。v1.0+：codecs 在 byte[3]；老版本：codecs 在 byte[4]。
    func parseCaps(_ data: [UInt8]) -> ATVVCapabilities? {
        guard data.count >= 7, data[0] == ATVV.opcodeCaps else { return nil }
        let version = (UInt16(data[1]) << 8) | UInt16(data[2])
        var codecs: Int
        var interaction: Int
        if version >= 0x0100 {
            codecs = Int(data[3])
            interaction = Int(data[4])
            if codecs == 0, data.count >= 9, (data[4] & 0x03) != 0 {
                codecs = Int(data[4])
                interaction = 0x03
            }
        } else {
            guard data.count >= 9 else { return nil }
            codecs = Int(data[4])
            interaction = 0x00
        }
        var frameSize = (Int(data[5]) << 8) | Int(data[6])
        if frameSize == 0 { frameSize = ATVV.defaultFrameSize }
        let selected = (codecs & 0x02) != 0 ? 0x02 : 0x01
        let sampleRate = selected == 0x02 ? 16000 : 8000
        return ATVVCapabilities(
            version: version, codecs: codecs, interaction: interaction,
            frameSize: frameSize, selectedCodec: selected, sampleRate: sampleRate
        )
    }

    /// 处理一条 CTL 通知。返回日志文本；调用方再根据首字节做状态分支。
    func handleControl(_ data: [UInt8]) -> String {
        guard let opcode = data.first else { return "空控制帧" }
        switch opcode {
        case ATVV.opcodeCaps:
            guard let caps = parseCaps(data) else { return "CAPS 解析失败：\(data)" }
            self.caps = caps
            self.version = caps.version
            self.frameSize = caps.frameSize
            return "CAPS version=\(String(format: "0x%04X", caps.version)) codecs=\(String(format: "0x%02X", caps.codecs)) frameSize=\(caps.frameSize) sampleRate=\(caps.sampleRate)"
        case ATVV.opcodeMicButton:
            return "MIC_BUTTON（话筒键按下）"
        case ATVV.opcodeAudioStart:
            decoder.reset()
            dcFilter.reset()
            accumulator.reset()
            pendingSync = nil
            micOpen = true
            if data.count >= 4 { lastSessionID = data[3] }
            let reason = data.count >= 2 ? data[1] : 0
            let codec = data.count >= 3 ? data[2] : 0
            return "AUDIO_START session=\(lastSessionID) reason=\(reason) codec=\(codec)"
        case ATVV.opcodeAudioStop:
            micOpen = false
            lastMicOffAt = Date()
            accumulator.reset()
            let reason = data.count >= 2 ? data[1] : 0
            return "AUDIO_STOP reason=\(reason)"
        case ATVV.opcodeAudioSync:
            guard data.count >= 7 else { return "AUDIO_SYNC 过短" }
            let raw = (Int(data[4]) << 8) | Int(data[5])
            let predictor = raw >= 0x8000 ? raw - 0x10000 : raw
            pendingSync = (predictor: predictor, stepIndex: Int(data[6]))
            return "AUDIO_SYNC predictor=\(predictor) stepIndex=\(data[6])"
        default:
            return String(format: "未知控制 opcode=0x%02X", opcode)
        }
    }

    /// 处理一条 AUDIO 通知，返回解码后的 16kHz PCM（可能为空）。
    func handleAudio(_ data: [UInt8]) -> [Int16] {
        if !micOpen {
            if let offAt = lastMicOffAt,
               Date().timeIntervalSince(offAt) < ATVV.lateAudioGuardSeconds {
                return []
            }
        }
        var out: [Int16] = []
        for frame in accumulator.append(data, frameSize: frameSize) {
            if let sync = pendingSync {
                decoder.reset(predictor: sync.predictor, stepIndex: sync.stepIndex)
                dcFilter.reset()
                pendingSync = nil
            }
            let decoded = decoder.decode(frame)
            let centered = dcFilter.process(decoded)
            out.append(contentsOf: atvvPostprocess(centered))
        }
        return out
    }
}

// MARK: - ATVV 引擎

/// 对外回调都在主线程触发（CBCentralManager 用主队列创建）。
final class ATVVEngine: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    /// 连接状态变化（直接用 Shared.ConnectionState，界面可直接显示 displayName）。
    var onConnection: ((ConnectionState) -> Void)?
    /// 话筒键按下（CTL MIC_BUTTON 0x08）。hold 模式：开始语音；toggle 模式：切换语音开关。
    var onVoiceButtonDown: (() -> Void)?
    /// 语音流结束（CTL AUDIO_STOP 0x00）。hold 模式：结束语音；toggle 模式：幂等停止。
    var onVoiceButtonUp: (() -> Void)?
    /// 解码后的 16kHz 单声道 PCM，流式到达（不写文件）。
    var onSamples: (([Int16]) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var state: ConnectionState = .disconnected

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var audioChar: CBCharacteristic?
    private var ctlChar: CBCharacteristic?

    private var session = ATVVSession()
    private var running = false
    private var capsReady = false
    private var autoReconnectAttempted = false
    private var suppressDisconnect = false
    /// 发现流程代次：超时闭包凭它识别过期任务，避免旧定时器干扰新一轮发现。
    private var discoveryToken = 0

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    // MARK: 公开方法

    func start() {
        guard !running else { return }
        running = true
        autoReconnectAttempted = false
        if central.state == .poweredOn {
            beginDiscovery()
        }
        // 蓝牙尚未就绪时，等 centralManagerDidUpdateState 回调再开始发现。
    }

    func stop() {
        running = false
        central.stopScan()
        if let peripheral = peripheral {
            suppressDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        txChar = nil
        audioChar = nil
        ctlChar = nil
        capsReady = false
        emit(.disconnected)
    }

    /// 手动重连：复位自动重连计数，重新发现设备。
    func reconnect() {
        guard running else { return }
        autoReconnectAttempted = false
        if let peripheral = peripheral {
            suppressDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        txChar = nil
        audioChar = nil
        ctlChar = nil
        capsReady = false
        beginDiscovery()
    }

    /// 打开麦克风（写 MIC_OPEN）。仅在已握手（CAPS 通过）后有效。
    func openMic() {
        guard capsReady else {
            log("未完成 CAPS 握手，忽略 openMic")
            return
        }
        writeTX(Data(ATVV.micOpenCommand(version: session.version)))
    }

    /// 关闭麦克风（写 MIC_CLOSE）。
    func closeMic() {
        guard capsReady else { return }
        writeTX(Data(ATVV.micCloseCommand(version: session.version, sessionID: session.lastSessionID)))
        session.micOpen = false
    }

    // MARK: 内部流程

    private func emit(_ newState: ConnectionState) {
        state = newState
        onConnection?(newState)
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private func beginDiscovery() {
        guard running else { return }
        discoveryToken += 1
        let token = discoveryToken
        emit(.scanning)
        // 优先找系统已连接的遥控器（它已在系统蓝牙里连着时最可靠）。
        let connected = central.retrieveConnectedPeripherals(withServices: [ATVV.service])
        if let first = connected.first(where: { ($0.name ?? "").contains("Chromecast") }) ?? connected.first {
            log("在系统已连接设备里找到：\(first.name ?? "未知")，正在连接…")
            peripheral = first
            emit(.connecting)
            central.connect(first, options: nil)
            return
        }
        log("系统已连接设备里没有 ATVV 设备，开始扫描广播…")
        central.scanForPeripherals(withServices: [ATVV.service], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self,
                  self.running,
                  self.discoveryToken == token,
                  self.peripheral == nil else { return }
            self.central.stopScan()
            self.fail("20 秒内没扫到带 ATVV 服务的设备，请确认遥控器已开机、在 Mac 附近、在系统蓝牙里可见")
        }
    }

    private func fail(_ reason: String) {
        guard running else { return }
        log("失败：\(reason)")
        central.stopScan()
        if let peripheral = peripheral {
            suppressDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        capsReady = false
        emit(.failed(reason))
    }

    private func writeTX(_ data: Data) {
        guard let tx = txChar, let peripheral = peripheral else { return }
        let type: CBCharacteristicWriteType =
            tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: tx, type: type)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if running, peripheral == nil {
                beginDiscovery()
            }
        case .poweredOff:
            fail("蓝牙未开启，请先在系统设置里打开蓝牙")
        case .unauthorized:
            emit(.unauthorized)
            log("蓝牙权限被拒绝：请在系统设置 → 隐私与安全性 → 蓝牙里允许本应用")
        case .unsupported:
            emit(.unsupported)
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        log("发现设备：\(peripheral.name ?? "未知") RSSI=\(RSSI)")
        self.peripheral = peripheral
        central.stopScan()
        emit(.connecting)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("已连接：\(peripheral.name ?? "未知")，发现 ATVV 服务…")
        // 每次连接用全新会话，避免解码器与帧状态跨连接泄漏。
        session = ATVVSession()
        capsReady = false
        peripheral.delegate = self
        peripheral.discoverServices([ATVV.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        if running, !autoReconnectAttempted {
            autoReconnectAttempted = true
            self.peripheral = nil
            beginDiscovery()
        } else {
            fail("连接遥控器失败：\(error?.localizedDescription ?? "未知错误")")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if suppressDisconnect {
            suppressDisconnect = false
            return
        }
        log("设备断开：\(error?.localizedDescription ?? "无错误信息")")
        guard running else { return }
        self.peripheral = nil
        capsReady = false
        if !autoReconnectAttempted {
            // 断线自动重连一次（仅一次，避免无限重连耗电）。
            autoReconnectAttempted = true
            log("断线，自动重连一次…")
            beginDiscovery()
        } else {
            emit(.failed("遥控器断开连接"))
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            fail("发现服务失败：\(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == ATVV.service }) else {
            fail("没找到 ATVV 服务（AB5E0001），这台遥控器可能不是 Chromecast 语音遥控器")
            return
        }
        log("找到 ATVV 服务，发现三个特征值…")
        peripheral.discoverCharacteristics([ATVV.tx, ATVV.audio, ATVV.control], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            fail("发现特征值失败：\(error.localizedDescription)")
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case ATVV.tx: txChar = char
            case ATVV.audio: audioChar = char
            case ATVV.control: ctlChar = char
            default: break
            }
        }
        guard txChar != nil, audioChar != nil, ctlChar != nil else {
            fail("特征值不全：TX=\(txChar != nil) AUDIO=\(audioChar != nil) CTL=\(ctlChar != nil)")
            return
        }
        log("三个特征值齐了，订阅 CTL + AUDIO 通知…")
        peripheral.setNotifyValue(true, for: ctlChar!)
        peripheral.setNotifyValue(true, for: audioChar!)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            fail("订阅通知失败 \(characteristic.uuid)：\(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == ATVV.control, characteristic.isNotifying, !capsReady else { return }
        // CTL 订阅成功后发 GET_CAPABILITIES。
        log("CTL 通知已开，发送 GET_CAPABILITIES…")
        writeTX(Data(ATVV.getCapabilitiesV10))
        let token = discoveryToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.running, self.discoveryToken == token, !self.capsReady else { return }
            self.fail("10 秒内没收到 CAPS 回复，遥控器可能不支持 ATVV v1.0 或需要先按话筒键")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            log("读取特征值失败 \(characteristic.uuid)：\(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        if characteristic.uuid == ATVV.control {
            let event = session.handleControl(bytes)
            log("CTL → \(event)")
            switch bytes.first {
            case ATVV.opcodeCaps:
                guard let caps = session.caps else { return }
                guard caps.sampleRate == ATVV.supportedSampleRate else {
                    // 8kHz 门控：拒绝猜测解码，避免静默误解码。
                    fail("设备只支持 \(caps.sampleRate) Hz 音频，本引擎要求 16kHz")
                    return
                }
                capsReady = true
                emit(.connected(peripheral.name ?? "Chromecast Remote"))
                log("握手完成（16kHz），等待话筒键…")
            case ATVV.opcodeMicButton:
                onVoiceButtonDown?()
            case ATVV.opcodeAudioStop:
                onVoiceButtonUp?()
            default:
                break
            }
        } else if characteristic.uuid == ATVV.audio {
            let samples = session.handleAudio(bytes)
            if !samples.isEmpty {
                onSamples?(samples)
            }
        }
    }
}
