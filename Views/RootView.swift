import SwiftUI
import UIKit

/// 书库导航栈里的路由：一本书的详情页，或一位作者的作品页
enum LibraryRoute: Hashable {
    case book(String)
    case author(String)
}

/// 底部标签页：书库、播放历史与「我」各挂一条独立导航栈
enum AppTab: Hashable, CaseIterable, Identifiable {
    case library
    case history
    case me

    var id: Self { self }

    var title: String {
        switch self {
        case .library: return "书库"
        case .history: return "历史"
        case .me: return "我"
        }
    }

    /// tab 栏图标：微信读书那样线框图标加小字，选中只靠主题色区分
    var icon: String {
        switch self {
        case .library: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        case .me: return "person"
        }
    }

    /// 选中时的实心图标
    var filledIcon: String {
        switch self {
        case .library: return "books.vertical.fill"
        case .history: return "clock.arrow.circlepath.fill"
        case .me: return "person.fill"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .library: return "tab-library"
        case .history: return "tab-history"
        case .me: return "tab-me"
        }
    }
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
    let meRouter = AppRouter()

    var active: AppRouter {
        switch selectedTab {
        case .library: return libraryRouter
        case .history: return historyRouter
        case .me: return meRouter
        }
    }

    func router(for tab: AppTab) -> AppRouter {
        switch tab {
        case .library: return libraryRouter
        case .history: return historyRouter
        case .me: return meRouter
        }
    }

    /// 再点当前 tab：把它的导航栈退到根页面
    func popToRoot(_ tab: AppTab) {
        router(for: tab).path = []
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

    /// 「正在播放」收起条。放在每个 tab 内容的底部安全区里，因此它悬在 tab 栏上方、
    /// 不会遮住 tab（参考微信听书：tab 在最下，播放条在其上）
    @ViewBuilder
    private var miniPlayerInset: some View {
        if player.currentBook != nil {
            MiniPlayerView { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { player.showPlayer = true } }
        }
    }

    /// 书库 tab：整条书库导航栈（首页、详情页、作者页）
    private var libraryTab: some View {
        NavigationStack(path: pathBinding(for: routers.libraryRouter)) {
            LibraryView()
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerInset }
    }

    /// 播放历史 tab：详情页压进本 tab 自己的栈，返回时回到历史页而不是书库
    private var historyTab: some View {
        NavigationStack(path: pathBinding(for: routers.historyRouter)) {
            HistoryView(onOpenBook: { routers.historyRouter.openBook(id: $0) })
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerInset }
    }

    /// 「我」tab：收听时长统计，排行里的书也压进本 tab 自己的栈
    private var meTab: some View {
        NavigationStack(path: pathBinding(for: routers.meRouter)) {
            MeView(onOpenBook: { routers.meRouter.openBook(id: $0) })
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerInset }
    }

    /// 一个 tab 的全部内容：自己的导航栈加自己那份 tab 栏。
    /// 每个 tab 各自画一份 tab 栏，高亮的就是本 tab（常量），不需要状态传播就能正确高亮；
    /// 系统 tab 栏（iOS 26 是悬浮玻璃胶囊，改不了样式）隐藏掉
    private func tabView(_ tab: AppTab) -> some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .library: libraryTab
                case .history: historyTab
                case .me: meTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabBarView(selection: tab) { tapped in
                // 再点当前 tab 退回根页面，其他情况切 tab
                if tapped == tab {
                    routers.popToRoot(tab)
                } else {
                    routers.selectedTab = tapped
                }
            }
        }
        // tab 栏要贴到屏幕最底（盖住主屏指示条），整块内容才会在底部留白
        .ignoresSafeArea(edges: .bottom)
        // 系统那一条悬浮玻璃 tab 栏藏掉（要从 tab 内容里声明才生效），用自绘的
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label(tab.title, systemImage: tab.icon) }
        .tag(tab)
    }

    var body: some View {
        ZStack {
            TabView(selection: $routers.selectedTab) {
                tabView(.library)
                tabView(.history)
                tabView(.me)
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

/// 底部标签栏：参考微信读书——通栏不透明底、顶部一条细分割线、图标加小字。
/// selection 由所属 tab 传入且永不变化（每个 tab 自己一份），避开 SwiftUI 子视图不刷新的坑
private struct TabBarView: View {
    let selection: AppTab
    let onTap: (AppTab) -> Void

    /// 图标加文字那一行的高度，与系统旧版 tab 栏齐平
    private static let contentHeight: CGFloat = 49

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    onTap(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isSelected ? tab.filledIcon : tab.icon)
                            .font(.system(size: 21))
                        Text(tab.title)
                            .font(.system(size: 10, weight: isSelected ? .medium : .regular))
                    }
                    .foregroundStyle(isSelected ? Color.indigo : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(tab.accessibilityIdentifier)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: Self.contentHeight)
        .frame(maxWidth: .infinity)
        // 主屏指示条那一条也归 tab 栏，背景铺满才不会有割裂感
        .padding(.bottom, HomeIndicator.inset)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }
}

/// 主屏指示条占掉的底部安全区高度：自绘 tab 栏要盖住它，按这个值给自己留白
@MainActor enum HomeIndicator {
    static var inset: CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            guard windowScene.activationState == .foregroundActive
                || windowScene.activationState == .foregroundInactive else { continue }
            if let keyWindow = windowScene.windows.first(where: \.isKeyWindow) {
                return keyWindow.safeAreaInsets.bottom
            }
            if let window = windowScene.windows.first {
                return window.safeAreaInsets.bottom
            }
        }
        return 0
    }
}
