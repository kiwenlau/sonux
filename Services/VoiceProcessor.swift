import AVFoundation
import Foundation
import MediaToolbox

// MARK: - 处理链

/// 语音增强的数字处理：削掉吃动态余量的低频轰鸣 → 抬一点清晰度 → 整体推响 →
/// 软限幅把峰值收回去。效果是小声的地方明显变响、本来就响的地方不破音，
/// 而不是单纯把音量顶到失真。
///
/// 只认 float32 的 PCM，格式不合就原样放行：宁可不做增强，也不把整数采样当浮点算坏。
struct VoiceEnhancer {
    /// 峰值上限（满刻度 1.0 之下留一点余量）与推响倍数：+9.5 dB 前置增益。
    /// 实测（tools/voice-boost-check.swift）：录得很响的一本 +0.6 dB、录得轻的一本 +5.9 dB，
    /// 两本之间的电平差从 10.2 dB 收到 5.2 dB——正是「录音电平不一」要治的病
    static let ceiling: Float = 0.95
    static let makeupGain: Float = 3.0
    /// 三段滤波：100 Hz 高通去隆隆、250 Hz 低架减浑浊、3 kHz 峰值抬字头清晰度
    static let highPassHz: Float = 100
    static let lowShelfHz: Float = 250
    static let lowShelfdB: Float = -3
    static let presenceHz: Float = 3000
    static let presencedB: Float = 4

    private static let maxChannels = 8

    /// 二节滤波器的转置直接 I 型：两个状态量，每采样 5 乘 2 加
    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var s1: Float = 0, s2: Float = 0

        mutating func run(_ input: Float) -> Float {
            let output = b0 * input + s1
            s1 = b1 * input - a1 * output + s2
            s2 = b2 * input - a2 * output
            return output
        }

        mutating func reset() {
            s1 = 0
            s2 = 0
        }
    }

    private var channels: [[Biquad]] = []
    private(set) var sampleRate: Float = 0
    /// 本次处理观察到的峰值，供主线程确认「处理链真的在动声音」
    private(set) var peak: Float = 0

    /// 采样率一到就按 RBJ 公式重算系数；声道数变了就补齐状态
    mutating func configure(sampleRate: Float, channels channelCount: Int) {
        guard sampleRate > 0, channelCount > 0 else { return }
        if self.sampleRate != sampleRate || channels.count != min(channelCount, Self.maxChannels) {
            self.sampleRate = sampleRate
            let template = [Self.highPass(f0: Self.highPassHz, q: 0.707, fs: sampleRate),
                            Self.lowShelf(f0: Self.lowShelfHz, db: Self.lowShelfdB, fs: sampleRate),
                            Self.peaking(f0: Self.presenceHz, db: Self.presencedB, q: 0.8, fs: sampleRate)]
            channels = Array(repeating: template, count: min(channelCount, Self.maxChannels))
        }
    }

    /// 就地处理系统给的缓冲：不复制、不分配内存——实时线程只做算术
    ///
    /// - Returns: 实际经过处理链的声道数（0 表示格式不合，原样放行）
    mutating func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Int {
        guard !channels.isEmpty, frames > 0 else { return 0 }
        let count = Int(bufferList.pointee.mNumberBuffers)
        guard count > 0 else { return 0 }
        // AudioBufferList 尾部那个 C 柔性数组在 Swift 里不是数组，只能按偏移自己走指针
        let offset = MemoryLayout<AudioBufferList>.stride - MemoryLayout<AudioBuffer>.stride
        let buffers = UnsafeMutableRawPointer(bufferList)
            .advanced(by: offset)
            .assumingMemoryBound(to: AudioBuffer.self)
        var localPeak: Float = 0
        var voiced = 0
        for index in 0..<count {
            let buffer = buffers[index]
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float32.self)
            // 一个缓冲里可能是交织的多个声道（mNumberChannels > 1），也可能是单声道一个缓冲
            let stride = max(1, Int(buffer.mNumberChannels))
            for lane in 0..<stride {
                guard voiced < channels.count else { break }
                let gain = Self.makeupGain
                let ceiling = Self.ceiling
                for frame in 0..<frames {
                    let at = frame * stride + lane
                    var value = samples[at]
                    for band in 0..<3 { value = channels[voiced][band].run(value) }
                    // 推响后用一条有理曲线软收峰值：小信号几乎等于原样放大，
                    // 大信号被压向 ceiling，不会像硬削顶那样炸出破音
                    let boosted = value * gain
                    value = boosted * ceiling / (ceiling + abs(boosted))
                    samples[at] = value
                    let magnitude = abs(value)
                    if magnitude > localPeak { localPeak = magnitude }
                }
                voiced += 1
            }
        }
        if localPeak > peak { peak = localPeak }
        return voiced
    }

    mutating func resetState() {
        for channel in channels.indices {
            for band in 0..<3 { channels[channel][band].reset() }
        }
        resetPeak()
    }

    /// 只清峰值统计，不动滤波器状态（主线程取走快照后调用）
    mutating func resetPeak() { peak = 0 }

    // MARK: 系数（RBJ Audio EQ Cookbook）

    private static func highPass(f0: Float, q: Float, fs: Float) -> Biquad {
        let w0 = 2 * Float.pi * f0 / fs
        let cosine = cos(w0), sine = sin(w0)
        let alpha = sine / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cosine) / 2 / a0, b1: -(1 + cosine) / a0, b2: (1 + cosine) / 2 / a0,
                      a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
    }

    private static func peaking(f0: Float, db: Float, q: Float, fs: Float) -> Biquad {
        let w0 = 2 * Float.pi * f0 / fs
        let cosine = cos(w0), sine = sin(w0)
        let alpha = sine / (2 * q)
        let a = pow(10, db / 40)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cosine / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * cosine / a0, a2: (1 - alpha / a) / a0)
    }

    /// 低架：只压 250 Hz 以下，拐点之上要回到 0 dB（不然大腿音没了、人声也薄）
    private static func lowShelf(f0: Float, db: Float, fs: Float) -> Biquad {
        let w0 = 2 * Float.pi * f0 / fs
        let cosine = cos(w0), sine = sin(w0)
        let a = pow(10, db / 40)
        // 斜率 S = 1（cookbook 的中间值）：过渡最平，不给拐点频率添谐振
        let alpha = sine / 2 * sqrt(2)
        let root = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosine + root
        return Biquad(b0: a * ((a + 1) - (a - 1) * cosine + root) / a0,
                      b1: 2 * a * ((a - 1) - (a + 1) * cosine) / a0,
                      b2: a * ((a + 1) - (a - 1) * cosine - root) / a0,
                      a1: -2 * ((a - 1) + (a + 1) * cosine) / a0,
                      a2: ((a + 1) + (a - 1) * cosine - root) / a0)
    }
}

// MARK: - 挂在 AVPlayerItem 上的处理链

/// C 接口那几个标记：头文件里的匿名枚举在 Swift 里不一定露出来，按位值自己写一份
private let tapFlagPostEffects: MTAudioProcessingTapCreationFlags = 1 << 1
private let tapFlagStartOfStream: MTAudioProcessingTapFlags = 1 << 8

/// AVPlayer 的实时 DSP 入口。
///
/// 现有 SDK 里没有「把 AVAudioEngine 挂到 AVPlayer」的构造器（AVPlayer 只有
/// init / init(url:) / init(playerItem:) 三个），而 audioMix 上的
/// MTAudioProcessingTap 从 iOS 6 起就是官方口子——好处是不用卡系统版本，
/// 也不用为了 EQ 把已经踩实的播放心跳换成引擎播。
///
/// 开关只切处理链里的那个布尔：tap 一直在链上，关着的时候一个采样都不动，
/// 所以听着歌随手开关都不会重接音频链路、不会卡顿。
final class VoiceTap {
    static let shared = VoiceTap()

    struct State {
        var enabled = false
        var enhancer = VoiceEnhancer()
        var calls = 0
        var frames = 0
        var peak: Float = 0
        var sampleRate: Float = 0
        var channelCount = 0
        /// 系统给的处理格式，主线程拿它判断「是不是 float32，处理链有没有真的生效」
        var formatNote = ""
    }

    /// 状态锁：实时线程与主线程都要碰这份状态。用 NSLock 而不是 OSAllocatedUnfairLock
    /// 的 withLock——那个闭包是 @Sendable 的，缓冲指针和计数都进不去（Swift 6 会直接报错）
    private let lock = NSLock()
    private var state = State()
    private let created: MTAudioProcessingTap?

    /// 一个 app 只有一条增强链：tap 是回调对象，换 item 时复用同一个就够
    private init() {
        created = VoiceTap.make()
    }

    var ref: MTAudioProcessingTap? { created }

    func setEnabled(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        state.enabled = on
        if !on { state.enhancer.resetState() }
    }

    /// 主线程读一次统计并清零计数：用来在日志里确认处理链确实在过音频
    func drainStats() -> (calls: Int, frames: Int, peak: Float, sampleRate: Float, channelCount: Int, format: String) {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = (state.calls, state.frames, state.peak, state.sampleRate, state.channelCount, state.formatNote)
        state.calls = 0
        state.frames = 0
        state.enhancer.resetPeak()
        state.peak = 0
        return snapshot
    }

    // MARK: 实时线程一侧

    /// prepare：系统说清它将送来什么格式。float32 PCM 才处理，
    /// 整型或别的位深一律不介入，免得把样本算坏
    func prepare(_ desc: AudioStreamBasicDescription) {
        let usable = desc.mFormatID == kAudioFormatLinearPCM
            && (desc.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && desc.mBitsPerChannel == 32
        lock.lock()
        state.sampleRate = Float(desc.mSampleRate)
        state.channelCount = Int(desc.mChannelsPerFrame)
        state.formatNote = usable
            ? "\(Int(desc.mSampleRate)) Hz / \(desc.mChannelsPerFrame) 声道 float32"
            : "\(desc.mBitsPerChannel) 位非 float PCM，不介入"
        if usable {
            state.enhancer.configure(sampleRate: Float(desc.mSampleRate),
                                     channels: Int(desc.mChannelsPerFrame))
        } else {
            state.enhancer = VoiceEnhancer()
        }
        let note = state.formatNote
        lock.unlock()
        NSLog("[sonux] voiceBoost: %@", note)
    }

    /// 就地改系统给的那块缓冲：开关没开时一个采样都不动
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, discontinuous: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard state.enabled else { return }
        // 滤波器状态必须跟着断点清掉，否则上一段的尾巴会串进这一句，听感是一声爆音
        if discontinuous { state.enhancer.resetState() }
        _ = state.enhancer.process(bufferList, frames: frames)
        state.calls += 1
        state.frames += frames
        state.peak = state.enhancer.peak
    }

    /// 给某条音轨造一份带处理链的混音参数；拿不到 tap 就返回 nil，播放保持原样
    func audioMix(trackID: CMPersistentTrackID) -> AVMutableAudioMix? {
        guard let created else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: nil)
        parameters.trackID = trackID
        parameters.audioTapProcessor = created
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    // MARK: C 回调（不能捕获上下文，只能走单例）

    private static func make() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: 0,
            clientInfo: nil,
            init: Self.onInit,
            finalize: Self.onFinalize,
            prepare: Self.onPrepare,
            unprepare: Self.onUnprepare,
            process: Self.onProcess
        )
        var tap: MTAudioProcessingTap?
        // 处理放在所有音效之后：变速不变调是播放器自己做的，我们在它的输出上加 EQ
        let status = MTAudioProcessingTapCreate(nil, &callbacks, tapFlagPostEffects, &tap)
        if status != noErr {
            NSLog("[sonux] voiceBoost: 创建音频处理 tap 失败 osstatus=%d", status)
            return nil
        }
        return tap
    }

    private static let onInit: MTAudioProcessingTapInitCallback = { _, _, storageOut in
        // 状态都挂在单例上，不需要 tapStorage；留着回调只是为了让 init/finalize 成对
        storageOut.pointee = nil
    }

    private static let onFinalize: MTAudioProcessingTapFinalizeCallback = { _ in }

    private static let onPrepare: MTAudioProcessingTapPrepareCallback = { _, _, format in
        VoiceTap.shared.prepare(format.pointee)
    }

    private static let onUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

    private static let onProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
        var sourceFlags: MTAudioProcessingTapFlags = 0
        var framesGot: CMItemCount = 0
        // 进来的 bufferList 里数据指针是 NULL：把它原样交给系统填，填回来就是源音频，
        // 就地改它（in-place），再把同一个 bufferList 作为输出交回去
        let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                       &sourceFlags, nil, &framesGot)
        guard status == noErr else {
            numberFramesOut.pointee = 0
            flagsOut.pointee = sourceFlags
            return
        }
        // 断点标记在两个地方都会给：进来时的 flags（跳转、切章后的第一块）和取源音频的返回标记
        let discontinuous = (flags & tapFlagStartOfStream) != 0 || (sourceFlags & tapFlagStartOfStream) != 0
        VoiceTap.shared.process(bufferList: bufferListInOut, frames: Int(framesGot), discontinuous: discontinuous)
        numberFramesOut.pointee = framesGot
        // 源音频标了「流已结束」要往外传，否则播放器等不到结尾
        flagsOut.pointee = sourceFlags
    }
}
