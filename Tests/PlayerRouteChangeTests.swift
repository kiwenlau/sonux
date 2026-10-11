import XCTest
import AVFoundation
@testable import Sonux

/// 「拔耳机 / 蓝牙断连要停播」的端到端验证。
///
/// 判定函数与 no-op 路径在 PlayerContractTests、PlayerNoopAndLocalizationTests 里已经钉住了，
/// 但那两处证明不了一件更要紧的事：订阅真的挂上了、通知里的 reason 真的解析得出来。
/// 所以这里起一个真在播的 AVPlayer，从外面投一条路由变化通知，看它停不停。
///
/// 测试宿主跑在模拟器里，书库来自同步脚本导入的真书；拿不到书或播放器起不来（无音频输出）
/// 就整例跳过，不算失败——这条用例的价值在真机上跑通，模拟器能跑通则说明订阅链路是通的。
@MainActor
final class PlayerRouteChangeTests: XCTestCase {
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 投一条系统那条路由变化通知，reason 按系统给的格式塞 NSNumber
    private func post(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: reason.rawValue)]
        )
    }

    /// 真起一次播放；起不来就跳过，起来了的交给调用方 stop
    private func playingService() async throws -> PlayerService {
        guard let book = SonuxRuntime.shared.library.books.first, let chapter = book.chapters.first else {
            throw XCTSkip("测试宿主书库为空，没有可播的文件")
        }
        let player = PlayerService()
        player.play(book: book, at: PlayPosition(chapterId: chapter.id, time: 0))
        // 留半秒：文件读不到、会话起不来的时候 item 会在这半秒里报失败，isPlaying 落回 false
        await settle(0.5)
        guard player.isPlaying else {
            player.stop()
            throw XCTSkip("播放器没能起来（测试宿主无音频输出或文件读不到）")
        }
        return player
    }

    func testOldDeviceUnavailablePauses() async throws {
        let player = try await playingService()
        defer { player.stop() }
        post(.oldDeviceUnavailable)
        for _ in 0..<20 {
            if !player.isPlaying { return }
            await settle(0.1)
        }
        XCTFail("旧输出设备消失后仍在播放：声音会转到本机喇叭外放")
    }

    func testNewDeviceAvailableKeepsPlaying() async throws {
        let player = try await playingService()
        defer { player.stop() }
        post(.newDeviceAvailable)
        await settle(0.5)
        XCTAssertTrue(player.isPlaying, "接上新设备不是「人走了」，不该把正在放的掐掉")
    }
}
