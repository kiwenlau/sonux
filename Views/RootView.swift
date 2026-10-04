import SwiftUI
import UIKit

/// 书库导航栈里的路由：一本书的详情页，或一位作者的作品页
enum LibraryRoute: Hashable {
    case book(String)
    case author(String)
}

/// 底部标签页：音频、历史与「我的」各挂一条独立导航栈
enum AppTab: Hashable, CaseIterable, Identifiable {
    case library
    case history
    case me

    var id: Self { self }

    var title: String {
        switch self {
        case .library: return L("Audio")
        case .history: return L("History")
        case .me: return L("Me")
        }
    }

    /// tab 栏图标：微信读书那样线框图标加小字，选中只靠主题色区分
    var icon: String {
        switch self {
        case .library: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .me: return "person"
        }
    }

    /// 选中时的实心图标；nil 表示这个符号没有 .fill 变体（如 waveform、clock.arrow.circlepath），
    /// 选中态只靠主题色区分——写个不存在的名字会画成空白
    var filledIcon: String? {
        switch self {
        case .library: return nil
        case .history: return nil
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
    /// 封面图：底部面板要晕上当前这本书封面的颜色
    @ObservedObject private var coverStore = CoverStore.shared

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

    /// 「继续收听」条。只要听过书就常显（没在播时挂的是最近收听的那本，见 SonuxApp）。
    /// 排在 tab 栏上方，与 tab 栏同在一块面板里（见 bottomPanel）
    @ViewBuilder
    private var miniPlayerBar: some View {
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
    }

    /// 播放历史 tab：详情页压进本 tab 自己的栈，返回时回到历史页而不是书库
    private var historyTab: some View {
        NavigationStack(path: pathBinding(for: routers.historyRouter)) {
            HistoryView(onOpenBook: { routers.historyRouter.openBook(id: $0) })
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    /// 「我」tab：收听时长统计
    private var meTab: some View {
        NavigationStack(path: pathBinding(for: routers.meRouter)) {
            MeView()
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    /// 一个 tab 的全部内容：自己的导航栈、正在播放条、再加自己那份 tab 栏。
    /// 每 tab 各自画一份 tab 栏，高亮的就是本 tab（常量），不需要状态传播就能正确高亮；
    /// 系统 tab 栏（iOS 26 是悬浮玻璃胶囊，改不了样式）隐藏掉。
    /// 面板排在正文下方而不是叠在上面：正文到面板上沿就截断，不会从底下滑过去
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

            bottomPanel(tab)
        }
        // tab 栏要贴到屏幕最底（盖住主屏指示条），整块内容才会在底部留白
        .ignoresSafeArea(edges: .bottom)
        // 系统那一条悬浮玻璃 tab 栏藏掉（要从 tab 内容里声明才生效），用自绘的
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label(tab.title, systemImage: tab.icon) }
        .tag(tab)
    }

    /// 面板出血用的封面：当前这本书的封面图（没提取到就不晕色）
    private var bleedCover: UIImage? {
        guard let book = player.currentBook else { return nil }
        return coverStore.image(for: book)
    }

    /// 底部一整块面板：「继续收听」条在上、tab 栏在下，两块共用同一层底
    /// （微信听书就是一整块，不是两条颜色不同的条），中间靠一条细分割线区隔
    private func bottomPanel(_ tab: AppTab) -> some View {
        VStack(spacing: 0) {
            miniPlayerBar

            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)

            TabBarView(selection: tab) { tapped in
                // 再点当前 tab 退回根页面，其他情况切 tab
                if tapped == tab {
                    routers.popToRoot(tab)
                } else {
                    routers.selectedTab = tapped
                }
            }
        }
        .background(BottomPanelBackground(cover: bleedCover))
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
        // 面板要晕封面色，但从列表直接进播放页时可能还没提取过封面，在这里补上
        .task(id: player.currentBook?.id) {
            guard let book = player.currentBook else { return }
            await coverStore.load(for: book)
        }
    }
}

/// 底部面板的底：白底上把当前这本书的封面糊开再压一层纱——只要封面的颜色晕染，
/// 不要形状。直接把面板做半透明行不通：系统材质模糊半径太小，纱一薄底下列表的
/// 白卡条纹就整条透上来（看着像渲染出错），纱一厚颜色也没了
struct BottomPanelBackground: View {
    /// 出血用的封面图；nil 就是纯底
    let cover: UIImage?

    var body: some View {
        ZStack {
            Color(.systemBackground)

            if let cover {
                // 先用 Color.clear 把尺寸定在面板上：封面是方的，scaledToFill 会撑到
                // 整屏宽那么高，直接放进 ZStack 会把面板底顶到正文区去糊住最后一排卡片
                Color.clear
                    .overlay(
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 60)
                    )
                    .clipped()
                    // 纱用同色底：浅色压淡、深色压暗，两种模式下文字都读得清
                    .overlay(Color(.systemBackground).opacity(0.5))
            }
        }
    }
}

/// 底部标签栏：参考微信读书——图标加小字，选中只换主题色。
/// 底色与上方的「继续收听」条共用，由 bottomPanel 统一铺，这里只管排版。
/// selection 由所属 tab 传入且永不变化（每个 tab 自己一份），避开 SwiftUI 子视图不刷新的坑
private struct TabBarView: View {
    let selection: AppTab
    let onTap: (AppTab) -> Void

    /// 图标加文字那一行的高度，与系统旧版 tab 栏齐平
    private static let contentHeight: CGFloat = 49
    /// 图标与顶部分割线之间的留白：不填满高度时图标会贴着边缘，
    /// 这段留白从主屏指示条那一条里扣，整条 tab 栏高度不变
    private static let topPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    onTap(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isSelected ? (tab.filledIcon ?? tab.icon) : tab.icon)
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
        .padding(.top, Self.topPadding)
        // 主屏指示条那一条也归 tab 栏，底铺满才不会有割裂感
        .padding(.bottom, max(HomeIndicator.inset - Self.topPadding, 0))
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
