import XCTest
@testable import Sonux

/// App 侧音量细调：档位对齐、等比增益、持久化。
///
/// 只跑不建 AVPlayerItem、不 activateAudioSession 的路径（与 PlayerAdvanceAndSleepTests 同一口径）：
/// setVolume 在没装载音频时只写档位与偏好，player 为 nil 那一行自然跳过。
///
/// 音量存在 UserDefaults.standard 的一个键上，每个用例先把它抹掉，
/// 免得上一条写的 62 串染到「没存过就是 100」这类断言。
@MainActor
final class PlayerVolumeTests: XCTestCase {
    private static let volumeKey = "playback.volumePercent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.volumeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.volumeKey)
        super.tearDown()
    }

    // MARK: - 档位对齐

    func testNormalizedVolume_clampsIntoRange() {
        XCTAssertEqual(PlayerService.normalizedVolume(-10), 0)
        XCTAssertEqual(PlayerService.normalizedVolume(110), 100)
    }

    func testNormalizedVolume_alignsToWholePercent() {
        // 滑杆按 1 一格吸附，浮点残差（41.999998）不该让读数跳成 41
        XCTAssertEqual(PlayerService.normalizedVolume(41.999998), 42)
        XCTAssertEqual(PlayerService.normalizedVolume(42.4), 42)
        XCTAssertEqual(PlayerService.normalizedVolume(42.6), 43)
    }

    // MARK: - 档位到增益

    func testGain_fullPercentMeansNoAttenuation() {
        // 100 就是原样出声：上限由系统音量决定，这里只往下减
        XCTAssertEqual(PlayerService.gain(forVolumePercent: 100), 1.0, accuracy: 1e-6)
    }

    func testGain_zeroPercentIsSilent() {
        XCTAssertEqual(PlayerService.gain(forVolumePercent: 0), 0)
        XCTAssertEqual(PlayerService.gain(forVolumePercent: -5), 0, "范围外按静音处理，不能变成负增益")
    }

    func testGain_isMonotonic() {
        var previous: Float = -1
        for percent in stride(from: 0.0, through: 100, by: 1) {
            let gain = PlayerService.gain(forVolumePercent: percent)
            XCTAssertGreaterThan(gain, previous, "\(percent) 处增益比上一格还小，音量会倒着走")
            previous = gain
        }
    }

    func testGain_isLogarithmicSoEveryStepSoundsEquallyLoud() {
        // 每格都是同样的比值（10^(30/20/100) ≈ 1.035，约 0.3 dB）：
        // 线性增益做不到这件事——高处每格听不出差别，低处一拖就没声
        let ratio = PlayerService.gain(forVolumePercent: 100) / PlayerService.gain(forVolumePercent: 99)
        for percent in [90.0, 70.0, 50.0, 30.0, 10.0] {
            let step = PlayerService.gain(forVolumePercent: percent) / PlayerService.gain(forVolumePercent: percent - 1)
            XCTAssertEqual(step, ratio, accuracy: 0.001, "\(percent) 处的每格比值与顶端不一致")
        }
    }

    func testGain_fineStepsCoverOneHardwareStep() {
        // 系统音量一共 16 档，一档约 6 dB；这里一格约 0.3 dB，
        // 所以两档系统音量之间的空隙能用十几格补上，这才是「要么太小要么太大」的解
        func db(_ percent: Double) -> Double {
            20 * log10(Double(PlayerService.gain(forVolumePercent: percent)))
        }
        let perStep = db(100) - db(99)
        XCTAssertLessThanOrEqual(perStep, 0.35, "一格太粗，还是踩不进两档系统音量之间")
        XCTAssertGreaterThan(db(100) - db(1), 25, "整根轴太短，低档位一挪就没声")
    }

    // MARK: - 生效与持久化

    func testSetVolume_publishesPercent() {
        let p = PlayerService()
        p.setVolume(62)
        XCTAssertEqual(p.volumePercent, 62)
        XCTAssertEqual(UserDefaults.standard.double(forKey: Self.volumeKey), 62)
    }

    func testSetVolume_reopensWithStoredPercent() {
        let p = PlayerService()
        p.setVolume(37)
        // 新建 PlayerService 等价于进程重开：音量跟着环境走，不该被抹回满格
        XCTAssertEqual(PlayerService().volumePercent, 37)
    }

    func testSetVolume_muteSurvivesRestart() {
        let p = PlayerService()
        p.setVolume(0)
        // 0 是个合法档位，读回时不能被「没存过就是 100」的兜底顶掉
        XCTAssertEqual(PlayerService().volumePercent, 0)
    }

    func testDefaultVolumeIsFullWhenNothingStored() {
        // 没存过就是满格：不能给用户本来听得好好的音量加一层看不见的衰减
        XCTAssertEqual(PlayerService().volumePercent, 100)
    }

    func testSetVolume_ignoresOutOfRangeAndKeepsRange() {
        let p = PlayerService()
        p.setVolume(180)
        XCTAssertEqual(p.volumePercent, 100)
        p.setVolume(-30)
        XCTAssertEqual(p.volumePercent, 0)
        XCTAssertEqual(PlayerService.volumeRange, 0...100)
        XCTAssertEqual(PlayerService.volumeStep, 1)
    }
}
