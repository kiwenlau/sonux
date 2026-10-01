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
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        // 退到后台时立刻落盘当前进度
                        if let position = player.currentPosition(), let book = player.currentBook {
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
    }
}
