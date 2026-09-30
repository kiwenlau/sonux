import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            LibraryView()
                .safeAreaInset(edge: .bottom) {
                    if player.currentBook != nil {
                        MiniPlayerView { showPlayer = true }
                    }
                }
        }
        .sheet(isPresented: $showPlayer) {
            if player.currentBook != nil {
                PlayerView()
            }
        }
        .tint(.indigo)
    }
}
