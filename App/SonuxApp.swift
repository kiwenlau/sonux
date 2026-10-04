import SwiftUI

@main
struct SonuxApp: App {
    @StateObject private var library = LibraryService()
    @StateObject private var player = PlayerService()
    @Environment(\.scenePhase) private var scenePhase

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
