import SwiftUI

/// 书库导航栈里的路由：一本书的详情页，或一位作者的作品页
enum LibraryRoute: Hashable {
    case book(String)
    case author(String)
}

/// 书库导航栈路径。列表行与卡片都不带系统箭头，入栈统一由代码发起；
/// 全屏播放页在 NavigationStack 之外，需要一个共享对象才能往栈里跳作者页
@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [LibraryRoute] = []

    /// 进入某本书的详情页
    func openBook(id: String) {
        path.append(.book(id))
    }

    /// 进入某位作者的作品页
    func openAuthor(_ author: String) {
        path.append(.author(author))
    }
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    @StateObject private var router = AppRouter()

    /// 栈内每一页的内容：按路由值取当前数据，书被删掉时页面自然变空
    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .book(let bookId):
            if let book = library.book(id: bookId) {
                BookDetailView(book: book)
            } else {
                EmptyView()
            }
        case .author(let name):
            // 作者页就是只装了一位作者作品的书库，整套界面（搜索、列表/卡片切换）与首页一致
            LibraryView(author: name)
        }
    }

    var body: some View {
        ZStack {
            NavigationStack(path: $router.path) {
                LibraryView()
                    .navigationDestination(for: LibraryRoute.self) { route in
                        destination(for: route)
                    }
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
        .environmentObject(router)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: player.showPlayer)
        .tint(.indigo)
    }
}
