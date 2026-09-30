import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        NavigationStack {
            LibraryView()
                .safeAreaInset(edge: .bottom) {
                    if player.currentBook != nil {
                        MiniPlayerView { player.showPlayer = true }
                    }
                }
        }
        .sheet(isPresented: $player.showPlayer) {
            if player.currentBook != nil {
                PlayerView()
            }
        }
        .tint(.indigo)
    }
}
