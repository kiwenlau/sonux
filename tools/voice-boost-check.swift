// 语音增强的离线验收：把 App 里那条处理链（Services/VoiceProcessor.swift 的 VoiceEnhancer）
// 原样搬出来，对真实有声书音频跑一遍，量前后的电平与频段。
//
// 为什么不在模拟器里听：这条链是纯算术，能不能验收看数字——
// 低频该被削掉、3 kHz 该抬起来、整体该变响、峰值不许越界、不许出 NaN。
// 处理链与 App 共用同一份源码，所以这里量到的就是真机上的行为。
//
// 用法：
//   xcrun --sdk macosx swiftc -O -o .tmp-shots/vbcheck \
//       tools/voice-boost-check.swift Services/VoiceProcessor.swift
//   .tmp-shots/vbcheck TestBooks/大败局/xx.mp3
// 不带参数时只跑合成信号（100 Hz / 1 kHz / 3 kHz 正弦与满幅测试）。
import AVFoundation
import Foundation

// MARK: - 量测工具

func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for value in samples { sum += Double(value) * Double(value) }
    return Float(sqrt(sum / Double(samples.count)))
}

/// 单极点低通后的 RMS：当作「低频能量」的代理，不需要 FFT
func lowEnergy(_ samples: [Float], cutoffHz: Float, sampleRate: Float) -> Float {
    let rc = 1.0 / (2 * .pi * Double(cutoffHz))
    let alpha = 1.0 / (rc * Double(sampleRate) + 1.0)
    var state: Float = 0
    var sum: Double = 0
    for value in samples {
        state += Float(alpha) * (value - state)
        sum += Double(state) * Double(state)
    }
    return Float(sqrt(sum / Double(max(1, samples.count))))
}

/// 谐振器（两极点）在某个频率上的成分能量：前后各测一次就能看出 EQ 有没有动到那一频段
func toneEnergy(_ samples: [Float], hz: Float, sampleRate: Float) -> Float {
    let theta = 2 * .pi * hz / sampleRate
    let radius: Float = 0.95
    let coefficient = 2 * radius * cos(theta)
    let feedback = radius * radius
    var y1: Float = 0, y2: Float = 0
    var sum: Double = 0
    for value in samples {
        let y = value + coefficient * y1 - feedback * y2
        y2 = y1
        y1 = y
        sum += Double(y) * Double(y)
    }
    return Float(sqrt(sum / Double(max(1, samples.count)))) / (1 - feedback)
}

/// 把 float 声道包成系统给 tap 的那种 AudioBufferList（非交织，一缓冲一声道）
func withBufferList<R>(channels: [UnsafeMutablePointer<Float>], frames: Int,
                       _ body: (UnsafeMutablePointer<AudioBufferList>) -> R) -> R {
    let headerSize = MemoryLayout<AudioBufferList>.stride - MemoryLayout<AudioBuffer>.stride
    let size = headerSize + MemoryLayout<AudioBuffer>.stride * channels.count
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    list.pointee.mNumberBuffers = UInt32(channels.count)
    let buffers = raw.advanced(by: headerSize).assumingMemoryBound(to: AudioBuffer.self)
    for (index, channel) in channels.enumerated() {
        var entry = AudioBuffer()
        entry.mDataByteSize = UInt32(frames * 4)
        entry.mNumberChannels = 1
        entry.mData = UnsafeMutableRawPointer(channel)
        buffers[index] = entry
    }
    return body(list)
}

// MARK: - 合成信号：判据不看音量旋钮，看它该动谁、不该动谁

func syntheticChecks() {
    let sampleRate: Float = 44_100
    let frames = 44_100   // 一秒
    var enhancer = VoiceEnhancer()
    enhancer.configure(sampleRate: sampleRate, channels: 1)

    func tone(hz: Float, amplitude: Float) -> [Float] {
        (0..<frames).map { amplitude * sin(2 * .pi * hz * Float($0) / sampleRate) }
    }

    func process(_ samples: [Float]) -> [Float] {
        var copy = samples
        copy.withUnsafeMutableBufferPointer { pointer in
            _ = withBufferList(channels: [pointer.baseAddress!], frames: samples.count) { list in
                enhancer.process(list, frames: samples.count)
            }
        }
        enhancer.resetState()
        return copy
    }

    print("== 合成信号（单声道 44.1 kHz，各 1 秒）==")
    // 用小振幅探频率响应：软限幅在小信号下几乎不介入，量到的就是「EQ + 补偿增益」本身
    let probes: [(String, Float)] = [("隆隆 60 Hz", 60), ("浑浊 150 Hz", 150), ("拐点 250 Hz", 250),
                                     ("中音 1 kHz", 1000), ("清晰 3 kHz", 3000), ("齿音 8 kHz", 8000)]
    for (name, hz) in probes {
        let before = tone(hz: hz, amplitude: 0.05)
        let after = process(before)
        let gain = 20 * log10f(max(rms(after), 1e-9) / max(rms(before), 1e-9))
        let peakOut = after.reduce(Float(0)) { max($0, abs($1)) }
        print(String(format: "%@：增益 %+5.1f dB，峰值 %.3f", name, gain, peakOut))
    }

    // 满幅与越界：软限幅必须把峰值收在 ceiling 之内
    let hot = process(tone(hz: 1000, amplitude: 0.999))
    let peak = hot.reduce(0) { max($0, abs($1)) }
    let over = hot.filter { abs($0) > 1.0 || $0.isNaN }.count
    print(String(format: "满幅 1 kHz：输出峰值 %.3f（上限 %.2f），越界或 NaN %d 个",
                 peak, VoiceEnhancer.ceiling, over))

    // 静音必须还是静音：处理链不能给自己加噪声
    let quiet = process([Float](repeating: 0, count: frames))
    print(String(format: "数字静音输入：输出 RMS %.8f（应为 0）", rms(quiet)))
}

// MARK: - 真实音频

func realFileCheck(url: URL) {
    guard let file = try? AVAudioFile(forReading: url) else {
        print("读不了：\(url.lastPathComponent)")
        return
    }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: file.fileFormat.sampleRate,
                               channels: file.fileFormat.channelCount,
                               interleaved: false)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil,
          let data = buffer.floatChannelData else { return }
    let channels = Int(format.channelCount)
    let frames = Int(buffer.frameLength)
    var originals: [[Float]] = (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }

    var enhancer = VoiceEnhancer()
    enhancer.configure(sampleRate: Float(format.sampleRate), channels: channels)
    _ = withBufferList(channels: (0..<channels).map { data[$0] }, frames: frames) { list in
        enhancer.process(list, frames: frames)
    }

    var beforeRMS: Double = 0, afterRMS: Double = 0
    var beforeLow: Double = 0, afterLow: Double = 0
    var beforeTone: Double = 0, afterTone: Double = 0
    var peak: Float = 0, over = 0, nan = 0
    for channel in 0..<channels {
        let before = originals[channel]
        let after = Array(UnsafeBufferPointer(start: data[channel], count: frames))
        originals[channel] = after
        beforeRMS += Double(rms(before)) * Double(rms(before))
        afterRMS += Double(rms(after)) * Double(rms(after))
        beforeLow += Double(lowEnergy(before, cutoffHz: 120, sampleRate: Float(format.sampleRate)))
        afterLow += Double(lowEnergy(after, cutoffHz: 120, sampleRate: Float(format.sampleRate)))
        beforeTone += Double(toneEnergy(before, hz: 3000, sampleRate: Float(format.sampleRate)))
        afterTone += Double(toneEnergy(after, hz: 3000, sampleRate: Float(format.sampleRate)))
        for value in after {
            let magnitude = abs(value)
            if magnitude.isNaN { nan += 1 }
            if magnitude > 1.0 { over += 1 }
            if magnitude > peak { peak = magnitude }
        }
    }
    let scale = Double(channels)
    print("== 真实音频：\(url.lastPathComponent)（\(Int(format.sampleRate)) Hz / \(channels) 声道 / \(frames / Int(format.sampleRate)) s）==")
    print(String(format: "整体响度  %.1f dB → %.1f dB（+%+.1f dB）",
                 10 * log10(Float(beforeRMS / scale)), 10 * log10(Float(afterRMS / scale)),
                 10 * log10(Float(afterRMS / max(beforeRMS, 1e-12)))))
    // 低频要看「占比」而不是绝对值：整体推响会把它一起抬上去，只有占比才看得出浑浊被削
    let lowShareBefore = 20 * log10(Float(beforeLow / scale)) - 10 * log10(Float(beforeRMS / scale))
    let lowShareAfter = 20 * log10(Float(afterLow / scale)) - 10 * log10(Float(afterRMS / scale))
    print(String(format: "低频占比（120 Hz 以下比整体）%+.1f dB → %+.1f dB（%+.1f dB，该降）",
                 lowShareBefore, lowShareAfter, lowShareAfter - lowShareBefore))
    print(String(format: "3 kHz 成分增益 %+.1f dB（该升）",
                 20 * log10(Float(afterTone / max(beforeTone, 1e-9)))))
    print(String(format: "输出峰值 %.3f（上限 %.2f），越界 %d 个，NaN %d 个", peak, VoiceEnhancer.ceiling, over, nan))
}

// 多文件编译时入口要挂在 @main 上（只有 main.swift 才允许裸写顶层语句）
@main
enum VoiceBoostCheck {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        syntheticChecks()
        if arguments.isEmpty {
            print("\n（没给音频文件：只跑了合成信号。带上一个 mp3/m4a 再跑一次能量对比。）")
        }
        for url in arguments {
            print("")
            realFileCheck(url: url)
        }
    }
}
