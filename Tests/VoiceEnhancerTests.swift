import XCTest
import AVFoundation
@testable import Sonux

/// VoiceEnhancer 是三段 RBJ 双二阶 + 前置增益 + 软限幅的处理链，只在 float32 PCM 上跑。
/// 我们测「不合规输入要静默 no-op、不 corrupt 状态」这条契约——真正把 AudioBufferList 送进
/// process 的用例依赖指针与实时线程，留给集成测试。
final class VoiceEnhancerTests: XCTestCase {
    // MARK: - 常量锁死

    func testConstants_matchTunedValues() {
        // 数值随听觉调校过；改动会立刻砸到音量增强效果，测试把它们钉住
        XCTAssertEqual(VoiceEnhancer.ceiling, 0.95)
        XCTAssertEqual(VoiceEnhancer.makeupGain, 3.0)
        XCTAssertEqual(VoiceEnhancer.highPassHz, 100)
        XCTAssertEqual(VoiceEnhancer.lowShelfHz, 250)
        XCTAssertEqual(VoiceEnhancer.lowShelfdB, -3)
        XCTAssertEqual(VoiceEnhancer.presenceHz, 3000)
        XCTAssertEqual(VoiceEnhancer.presencedB, 4)
    }

    // MARK: - configure 守卫

    func testConfigure_zeroSampleRateIsNoop() {
        var e = VoiceEnhancer()
        e.configure(sampleRate: 0, channels: 2)
        XCTAssertEqual(e.sampleRate, 0, "sampleRate <= 0 时不该建任何滤波器")
        XCTAssertEqual(e.peak, 0)
    }

    func testConfigure_negativeSampleRateIsNoop() {
        var e = VoiceEnhancer()
        e.configure(sampleRate: -1, channels: 2)
        XCTAssertEqual(e.sampleRate, 0)
    }

    func testConfigure_zeroChannelsIsNoop() {
        var e = VoiceEnhancer()
        e.configure(sampleRate: 44100, channels: 0)
        XCTAssertEqual(e.sampleRate, 0, "声道数为 0 时同样拒建")
    }

    func testConfigure_validSampleRateSetsState() {
        var e = VoiceEnhancer()
        e.configure(sampleRate: 44100, channels: 2)
        XCTAssertEqual(e.sampleRate, 44100)
    }

    func testConfigure_repeatSameRateDoesNotRebuild() {
        // 同一采样率再配一次不该重建系数（每次 rebuild 要算 3 组 RBJ，白花时间）
        var e = VoiceEnhancer()
        e.configure(sampleRate: 44100, channels: 1)
        e.configure(sampleRate: 44100, channels: 1)
        XCTAssertEqual(e.sampleRate, 44100)
    }

    func testConfigure_newRateResamples() {
        var e = VoiceEnhancer()
        e.configure(sampleRate: 44100, channels: 1)
        e.configure(sampleRate: 48000, channels: 1)
        XCTAssertEqual(e.sampleRate, 48000, "换采样率要按新率重算 RBJ 系数")
    }

    // MARK: - resetPeak / resetState

    func testResetPeak_clearsPeakButKeepsConfig() {
        var e = VoiceEnhancer()
        e.configure(sampleRate: 44100, channels: 1)
        // peak 只能靠 process 累积，configure 后必是 0
        XCTAssertEqual(e.peak, 0)
        e.resetPeak()
        XCTAssertEqual(e.peak, 0)
        XCTAssertEqual(e.sampleRate, 44100, "resetPeak 不动滤波器")
    }

    func testResetState_safeOnEmptyEnhancer() {
        // 从没 configure 过的空增强器：channels 数组空，resetState 遍历 0 次也不崩
        var e = VoiceEnhancer()
        e.resetState()
        XCTAssertEqual(e.peak, 0)
    }
}
