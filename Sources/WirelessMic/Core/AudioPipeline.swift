// AudioPipeline.swift
// 把 ATVV 解码出的 16kHz PCM 实时送到指定 CoreAudio 输出设备（默认 BlackHole 2ch）。
// 实现：HAL 输出单元（AUHAL）直连设备，不经过 AVAudioEngine、不改系统默认输出设备。
// 注意：AVAudioEngine 的输出节点没有 audioUnit 属性（只有 auAudioUnit，且无法据此选设备），
// 因此设备选择必须用 HAL 单元 + kAudioOutputUnitProperty_CurrentDevice，这是标准做法。
// 流程：设备名 → 查设备 ID → 查设备标称采样率 → 建 HAL 单元 → 选设备 → 定输出格式
// （标称采样率、双声道、Float32 交错）→ 挂渲染回调 → 初始化 → 启动。
// 采样率/声道/格式不一致时用 AVAudioConverter 重采样；环空时渲染回调直接输出静音。
// 线程：push() 由 ATVV 回调（主线程）调用；渲染回调在音频实时线程，环形缓冲用 NSLock 保护。

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

enum AudioPipelineError: Error, LocalizedError {
    case deviceNotFound(name: String, available: [String])
    case deviceSetFailed(String, status: OSStatus)
    case audioUnitUnavailable
    case formatCreationFailed
    case converterCreationFailed
    case sampleRateQueryFailed(String)
    case unitStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let name, let available):
            let list = available.isEmpty ? "（未枚举到任何输出设备）" : available.joined(separator: "、")
            return "找不到输出设备“\(name)”（当前可用：\(list)）。请先安装 BlackHole 或在设置里改设备名。"
        case .deviceSetFailed(let name, let status):
            return "无法把输出设备设为“\(name)”（OSStatus=\(status)）。"
        case .audioUnitUnavailable:
            return "无法创建音频输出单元。"
        case .formatCreationFailed:
            return "无法创建音频格式。"
        case .converterCreationFailed:
            return "无法创建重采样器。"
        case .sampleRateQueryFailed(let name):
            return "无法读取输出设备“\(name)”的标称采样率。"
        case .unitStartFailed(let status):
            return "音频输出单元启动失败（OSStatus=\(status)）。"
        }
    }
}

/// 线程安全的定长环形缓冲（16kHz 单声道 Int16）。写满时丢弃最旧数据，
/// 保证延迟不越攒越大；读端永远拿到最新语音。
private final class RingBuffer {
    private var buffer: [Int16]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) {
        buffer = [Int16](repeating: 0, count: capacity)
    }

    var currentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        count = 0
    }

    func write(_ samples: [Int16]) {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            if count == buffer.count {
                readIndex = (readIndex + 1) % buffer.count
                count -= 1
            }
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % buffer.count
            count += 1
        }
    }

    /// 读出最多 maxCount 个采样，返回实际读到的个数。
    func read(into dest: UnsafeMutablePointer<Int16>, maxCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = min(count, maxCount)
        for i in 0..<n {
            dest[i] = buffer[readIndex]
            readIndex = (readIndex + 1) % buffer.count
        }
        count -= n
        return n
    }
}

final class AudioPipeline {

    /// 渲染期错误（如重采样失败），由 MicEngine 记入日志。
    var onError: ((String) -> Void)?

    /// 当前输出设备名（setDevice 会在运行中重启管线以切换设备）。
    var deviceName: String

    private(set) var isRunning = false

    private var unit: AudioUnit?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var stagingBuffer: AVAudioPCMBuffer?
    private var renderOutputBuffer: AVAudioPCMBuffer?
    /// 约 2 秒容量的输入环（16kHz 单声道）。
    private let ring = RingBuffer(capacity: 32768)

    init(deviceName: String = "BlackHole 2ch") {
        self.deviceName = deviceName
    }

    deinit {
        if isRunning {
            stop()
        }
    }

    // MARK: 公开方法

    /// 启动 HAL 单元并把它指向 deviceName 对应的设备。设备不存在时抛可读错误。
    func start() throws {
        guard !isRunning else { return }
        let deviceID = try findDeviceID(named: deviceName)
        let rate = try nominalSampleRate(for: deviceID)

        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        ) else {
            throw AudioPipelineError.formatCreationFailed
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true
        ) else {
            throw AudioPipelineError.formatCreationFailed
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioPipelineError.converterCreationFailed
        }
        // 采样率转换质量用默认值（语音场景足够）；不在此指定，避免 SDK 间类型差异。
        guard let staging = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 8192) else {
            throw AudioPipelineError.formatCreationFailed
        }
        self.inputFormat = inFormat
        self.outputFormat = outFormat
        self.converter = converter
        self.stagingBuffer = staging
        self.renderOutputBuffer = nil
        ring.reset()

        // 建 HAL 输出单元。
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioPipelineError.audioUnitUnavailable
        }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let newUnit = newUnit else {
            throw AudioPipelineError.audioUnitUnavailable
        }

        // 选设备（只改本单元，不动系统默认输出设备）。
        var deviceIDVar = deviceID
        var status = AudioUnitSetProperty(
            newUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(newUnit)
            throw AudioPipelineError.deviceSetFailed(deviceName, status: status)
        }

        // 定输出格式：设备标称采样率、双声道、Float32 交错。
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            newUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(newUnit)
            throw AudioPipelineError.deviceSetFailed(deviceName, status: status)
        }

        // 挂渲染回调（闭包不捕获任何变量，只经 refCon 取回 self，可转 C 函数指针）。
        let callbackProc: AURenderCallback = { refCon, _, _, _, inNumberFrames, ioData in
            guard let ioData = ioData else { return noErr }
            let pipeline = Unmanaged<AudioPipeline>.fromOpaque(refCon).takeUnretainedValue()
            return pipeline.renderHAL(frameCount: inNumberFrames, outputData: ioData)
        }
        var callback = AURenderCallbackStruct(
            inputProc: callbackProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            newUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(newUnit)
            throw AudioPipelineError.deviceSetFailed(deviceName, status: status)
        }

        status = AudioUnitInitialize(newUnit)
        guard status == noErr else {
            AudioComponentInstanceDispose(newUnit)
            throw AudioPipelineError.unitStartFailed(status)
        }
        status = AudioOutputUnitStart(newUnit)
        guard status == noErr else {
            AudioUnitUninitialize(newUnit)
            AudioComponentInstanceDispose(newUnit)
            throw AudioPipelineError.unitStartFailed(status)
        }
        self.unit = newUnit
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        // 先停单元（此后不再有渲染回调），再释放资源，避免回调与释放竞态。
        if let unit = unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        converter = nil
        stagingBuffer = nil
        renderOutputBuffer = nil
        inputFormat = nil
        outputFormat = nil
        ring.reset()
        isRunning = false
    }

    /// 切换输出设备。运行中会重启管线；新设备不存在时抛错且管线保持停止，
    /// 调用方（MicEngine）据此决定是否结束语音会话。
    func setDevice(_ name: String) throws {
        let wasRunning = isRunning
        if wasRunning { stop() }
        deviceName = name
        if wasRunning { try start() }
    }

    /// 送入一包解码后的 16kHz PCM。未运行时丢弃。
    func push(_ samples: [Int16]) {
        guard isRunning, !samples.isEmpty else { return }
        ring.write(samples)
    }

    // MARK: 设备枚举与查询（CoreAudio）

    private func listDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids.map { id in (id, deviceName(for: id) ?? "未知设备 \(id)") }
    }

    private func deviceName(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &nameSize, &name) == noErr else {
            return nil
        }
        return name as String
    }

    private func findDeviceID(named name: String) throws -> AudioDeviceID {
        let devices = listDevices()
        if let match = devices.first(where: { $0.name == name }) {
            return match.id
        }
        throw AudioPipelineError.deviceNotFound(name: name, available: devices.map(\.name))
    }

    /// 查设备标称采样率（HAL 输入格式必须与它一致，否则变调）。
    private func nominalSampleRate(for id: AudioDeviceID) throws -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
            throw AudioPipelineError.sampleRateQueryFailed(deviceName)
        }
        return rate
    }

    // MARK: 渲染（音频实时线程，临界区保持极短）

    private func renderHAL(
        frameCount: UInt32,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let outList = UnsafeMutableAudioBufferListPointer(outputData)
        // 先全部静音：缺数据时输出静音，不输出残留噪声。
        for buffer in outList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        // 环空时直接静音，不跑转换器。
        guard ring.currentCount > 0,
              let converter = converter,
              let outFormat = outputFormat else {
            return noErr
        }
        // 转换结果缓冲复用（渲染回调是串行的，复用安全）；帧数超限时扩容。
        if renderOutputBuffer == nil || renderOutputBuffer!.frameCapacity < AVAudioFrameCount(frameCount) {
            renderOutputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frameCount))
        }
        guard let temp = renderOutputBuffer else { return noErr }

        var convertError: NSError?
        let status = converter.convert(to: temp, error: &convertError) { [weak self] requested, statusPtr in
            guard let self = self, let staging = self.stagingBuffer,
                  let channelData = staging.int16ChannelData else {
                statusPtr.pointee = .noDataNow
                return nil
            }
            // 转换器要多少给多少，不超供、不丢数；环空了就报 noDataNow。
            let filled = self.ring.read(into: channelData[0], maxCount: Int(requested))
            if filled == 0 {
                statusPtr.pointee = .noDataNow
                return nil
            }
            staging.frameLength = AVAudioFrameCount(filled)
            statusPtr.pointee = .haveData
            return staging
        }
        if status == .error {
            onError?("重采样失败：\(convertError?.localizedDescription ?? "未知错误")")
            return noErr
        }
        // 转换结果与 HAL 输出格式同布局，按 buffer 逐个拷贝；尾部已预先静音。
        // 注意：AVAudioPCMBuffer.audioBufferList 是不可变指针，这里只读不写，
        // 用 UnsafeMutablePointer(mutating:) 转成可变指针包装（不实际修改）。
        let tempList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: temp.audioBufferList))
        for i in 0..<min(tempList.count, outList.count) {
            guard let src = tempList[i].mData, let dst = outList[i].mData else { continue }
            let bytes = min(Int(tempList[i].mDataByteSize), Int(outList[i].mDataByteSize))
            memcpy(dst, src, bytes)
        }
        return noErr
    }
}
