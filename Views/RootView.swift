import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ZStack {
            NavigationStack {
                LibraryView()
                    .safeAreaInset(edge: .bottom) {
                        if player.currentBook != nil {
                            MiniPlayerView { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { player.showPlayer = true } }
                        }
                    }
            }

            // 全屏覆盖式播放页（不用 sheet，避免状态栏区域露出系统底色），从底部滑入
            if player.showPlayer, player.currentBook != nil {
                PlayerView()
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: player.showPlayer)
        .tint(.indigo)
    }
}
