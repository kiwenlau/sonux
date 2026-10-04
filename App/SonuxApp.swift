import SwiftUI

@main
struct SonuxApp: App {
    @StateObject private var library = LibraryService()
    @StateObject private var player = PlayerService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        TouchTracer.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .task {
                    library.bootstrap()
                    wireProgressPersistence()
                    restoreContinueListening()
                }
                // 播放器的书被清空（播完、停掉）或书库变动（删书、扫完）后重新挂一本，保证条不断档
                .onChange(of: player.currentBook?.id) { _ in restoreContinueListening() }
                .onChange(of: library.books.count) { _ in restoreContinueListening() }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        // 退到后台时立刻落盘当前进度（只挂着没听的状态不必写，否则会顶掉最后收听时间）
                        if player.hasPlayer, let position = player.currentPosition(), let book = player.currentBook {
                            library.recordPosition(position, bookId: book.id)
                        }
                    case .active:
                        // 回到前台时刷新书库（电脑可能刚同步了新文件）
                        // 冷启动时 bootstrap 已经在扫了，首次 .active 不必再扫一遍
                        if library.hasFinishedFirstScan {
                            library.rescan()
                        }
                    default:
                        break
                    }
                }
        }
    }

    /// 底部「继续收听」条常显：播放器里没挂书时（冷启动、播完、删书），
    /// 把最近收听的那本连进度一起挂上，不装载播放器也不抢音频焦点
    private func restoreContinueListening() {
        // 挂着没播的那本已被删掉：先卸掉，再挂下一本
        if !player.hasPlayer, let prepared = player.currentBook, library.book(id: prepared.id) == nil {
            player.unloadPrepared()
        }
        guard !player.hasPlayer, player.currentBook == nil else { return }
        guard let entry = library.historyEntries().first,
              let chapter = entry.chapter ?? entry.book.chapters.first else { return }
        player.prepareToResume(book: entry.book, chapter: chapter, at: entry.position?.time ?? 0)
    }

    /// 把播放器的进度回调接到书库持久化上
    private func wireProgressPersistence() {
        player.onPositionChange = { [weak library, weak player] position in
            guard let library, let bookId = player?.currentBook?.id else { return }
            library.recordPosition(position, bookId: bookId)
        }
        // 自动续播下一章时，查询该章节自己的历史播放位置
        player.chapterHistory = { [weak library] chapterId in
            library?.position(forChapter: chapterId)
        }
        // 收听时长累加：同一秒内紧跟着的 recordPosition 会把统计一起落盘
        player.onListening = { [weak library] seconds, bookId in
            library?.addListening(seconds: seconds, bookId: bookId)
        }
    }
}

#if DEBUG
/// 诊断用触摸探针：把每一笔按下/抬起都落到日志里，一次回答三个问题 ——
/// ① 点有没有进到窗口里；② 命中测试拿到的是哪个视图；③ 当时 App 是不是前台活跃、窗口是不是 key。
/// 「点了没反应」的锅可能在事件路由（根本没进来 / 命中了空视图），也可能在手势层（进来了但没动作），
/// 没有这一层日志就只能靠猜。Release 编译成空实现，不会带进正式版。
enum TouchTracer {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let probe = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.probe_sendEvent(_:)))
        else {
            NSLog("[sonux] probe: 装不上（取不到 sendEvent 方法）")
            return
        }
        method_exchangeImplementations(original, probe)
        observeLifecycle()
        NSLog("[sonux] probe: 触摸探针已装上")
    }

    /// 前台/后台切换是「触摸被系统丢掉」最常见的成因，一并落日志
    private static func observeLifecycle() {
        let notes: [(String, Notification.Name)] = [
            ("成为前台活跃", UIApplication.didBecomeActiveNotification),
            ("失去前台活跃", UIApplication.willResignActiveNotification),
            ("进入后台", UIApplication.didEnterBackgroundNotification),
            ("即将回到前台", UIApplication.willEnterForegroundNotification),
        ]
        for (name, note) in notes {
            NotificationCenter.default.addObserver(forName: note, object: nil, queue: .main) { _ in
                NSLog("[sonux] probe: App %@", name)
            }
        }
    }
}

extension UIWindow {
    /// 交换实现之后，调这个名字实际执行的是原来的 sendEvent
    @objc func probe_sendEvent(_ event: UIEvent) {
        probe_sendEvent(event)
        guard event.type == .touches, let touches = event.allTouches else { return }
        for touch in touches {
            let phase: String
            switch touch.phase {
            case .began: phase = "按下"
            case .ended: phase = "抬起"
            case .cancelled: phase = "取消"
            default: continue
            }
            let point = touch.location(in: self)
            let hit = hitTest(point, with: event)
            var target = hit.map { String(describing: type(of: $0)) } ?? "nil（没命中任何视图）"
            if let id = hit?.accessibilityIdentifier, !id.isEmpty { target += "[\(id)]" }
            let state: String
            switch UIApplication.shared.applicationState {
            case .active: state = "前台活跃"
            case .inactive: state = "不活跃"
            case .background: state = "后台"
            @unknown default: state = "未知"
            }
            NSLog("[sonux] probe: %@ %@ 窗口=%@ key=%@ 点=(%.0f,%.0f) 命中=%@",
                  phase, state, String(describing: type(of: self)),
                  isKeyWindow ? "是" : "否", point.x, point.y, target)
        }
    }
}
#else
enum TouchTracer {
    static func install() {}
}
#endif
