import SwiftUI

/// 书库导航栈里的路由：一本书的详情页，或一位作者的作品页
enum LibraryRoute: Hashable {
    case book(String)
    case author(String)
}

/// 底部标签页：书库与播放历史各挂一条独立导航栈
enum AppTab: Hashable {
    case library
    case history
}

/// 一个 tab 的导航栈路径。列表行与卡片都不带系统箭头，入栈统一由代码发起；
/// 全屏播放页在所有栈之外，需要一个共享对象才能往当前 tab 的栈里跳作者页
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

/// 各 tab 的导航栈集合 + 当前所在 tab。
/// 播放页点作者名时跳的是「当前 tab」的栈：在历史 tab 打开的播放页，就回落到历史栈
@MainActor
final class TabRouters: ObservableObject {
    @Published var selectedTab: AppTab = .library
    let libraryRouter = AppRouter()
    let historyRouter = AppRouter()

    var active: AppRouter {
        switch selectedTab {
        case .library: return libraryRouter
        case .history: return historyRouter
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    @StateObject private var routers = TabRouters()

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

    /// NavigationStack 的 path 绑定。`$routers.xxxRouter.path` 这种嵌套属性包装写不了，
    /// 手工包一层 Binding，set 时回写到对应 AppRouter
    private func pathBinding(for router: AppRouter) -> Binding<[LibraryRoute]> {
        Binding(get: { router.path }, set: { router.path = $0 })
    }

    /// 书库 tab：整条书库导航栈（首页、详情页、作者页）
    private var libraryTab: some View {
        NavigationStack(path: pathBinding(for: routers.libraryRouter)) {
            LibraryView()
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .tabItem { Label("书库", systemImage: "books.vertical") }
        .accessibilityIdentifier("tab-library")
    }

    /// 播放历史 tab：详情页压进本 tab 自己的栈，返回时回到历史页而不是书库
    private var historyTab: some View {
        NavigationStack(path: pathBinding(for: routers.historyRouter)) {
            HistoryView(onOpenBook: { routers.historyRouter.openBook(id: $0) })
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
        .accessibilityIdentifier("tab-history")
    }

    var body: some View {
        ZStack {
            TabView(selection: $routers.selectedTab) {
                libraryTab
                    .tag(AppTab.library)
                historyTab
                    .tag(AppTab.history)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.currentBook != nil {
                    MiniPlayerView { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { player.showPlayer = true } }
                }
            }

            // 全屏覆盖式播放页（不用 sheet，避免状态栏区域露出系统底色），从底部滑入
            if player.showPlayer, player.currentBook != nil {
                PlayerView()
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .environmentObject(routers)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: player.showPlayer)
        .tint(.indigo)
    }
}
