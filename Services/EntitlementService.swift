import Foundation
import StoreKit

/// 付费判定的纯逻辑：7 天试用只开收听报告，播放控制层只有 Pro 才有，
/// 没 Pro 的人（含试用期内）每天只给 30 分钟收听。
/// 字幕、逐句搜索与摘录不在这里：它们只看该书有没有字幕文件，不看付费状态。
/// 不碰商店也不碰界面，测试直接摆日期与秒数就能验
enum EntitlementPolicy {
    /// App Store Connect 里的两件商品：永久买断与月度订阅
    static let lifetimeID = "com.kiwenlau.sonux.pro"
    static let monthlyID = "com.kiwenlau.sonux.pro.monthly"

    static let trialDuration: TimeInterval = 7 * 24 * 60 * 60
    /// 免费与试用期每天的收听上限（墙钟秒，倍速不放大）
    static let dailyFreeSeconds: TimeInterval = 30 * 60

    static let trialStartKey = "entitlement.trialStart"
    static let purchasedKey = "entitlement.purchased"
    static let subscribedKey = "entitlement.subscribed"
    static let usageDayKey = "usage.day"
    static let usageSecondsKey = "usage.seconds"

    /// 试用期是否还在走：只管收听报告
    static func inTrial(trialStart: Date, now: Date,
                        trialDuration: TimeInterval = EntitlementPolicy.trialDuration) -> Bool {
        now.timeIntervalSince(trialStart) < trialDuration
    }

    /// 试用还剩几天（不足一天按一天报）；过完返回 nil
    static func trialDaysLeft(trialStart: Date, now: Date,
                              trialDuration: TimeInterval = EntitlementPolicy.trialDuration) -> Int? {
        let left = trialDuration - now.timeIntervalSince(trialStart)
        guard left > 0 else { return nil }
        return max(1, Int(ceil(left / (24 * 60 * 60))))
    }

    /// 今天到点没有
    static func capReached(todaySeconds: TimeInterval,
                           cap: TimeInterval = EntitlementPolicy.dailyFreeSeconds) -> Bool {
        todaySeconds >= cap
    }

    /// 收听记录按本地日历天归零，所以「哪一天」要参与判定
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// 付费闸门的状态与商店往来。
///
/// 真相源是 StoreKit 的 `Transaction.currentEntitlements`；本地那几份标记只是冷启动的秒开缓存——
/// 启动先照它们画界面，商店回话后再以商店为准修正。
@MainActor
final class EntitlementService: ObservableObject {
    static let shared = EntitlementService()

    /// 买断或订阅任一在手
    @Published private(set) var isPurchased: Bool
    @Published private(set) var isSubscribed: Bool
    /// 各入口上锁后要把用户领去 Paywall：呈现与关闭都由 RootView 读写
    @Published var isPaywallPresented = false
    /// 商店里那两件商品，价格由它们给（界面不硬编码金额，换区换档才不会说谎）
    @Published private(set) var lifetime: Product?
    @Published private(set) var monthly: Product?
    /// 购买或恢复失败时在 Paywall 上说一句
    @Published var purchaseFailed = false
    /// 今天的 30 分钟用完了：只翻转一次，界面据此提示
    @Published private(set) var dailyCapReached = true

    /// 试用起点：第一次读到付费判定的那一刻定下，之后不再改
    private let trialStart: Date

    /// 开发版默认全功能放行：不然作者自己手机上天天得给自己兑一次优惠码。
    /// Release 编译时这条恒为假，付费规则一字不改地生效；
    /// 带 `-SONUXDebugLocked 1` 启动可以把真规则找回来，用来在真机上验付费墙与每日 30 分钟
    private let unlockedForDevelopment: Bool

    /// Pro：播放控制层（语速、定时关闭、音量细调、跳过静音与语音增强）与不限时长
    var isPro: Bool { isPurchased || isSubscribed || unlockedForDevelopment }

    /// 收听报告：Pro 或试用期内。字幕那一类不在这里——它们不上锁，
    /// 只在该书有字幕文件时才出现（见 TranscriptStore）
    var hasReportAccess: Bool {
        isPro || EntitlementPolicy.inTrial(trialStart: trialStart, now: Date())
    }

    /// 要不要计每天的时长：只有 Pro 不计
    var isMetered: Bool { !isPro }

    var trialDaysLeft: Int? {
        guard !isPro else { return nil }
        return EntitlementPolicy.trialDaysLeft(trialStart: trialStart, now: Date())
    }

    /// 今天还能听多少秒；Pro 返回 nil（没有上限这回事）
    var timeLeftToday: TimeInterval? {
        guard isMetered else { return nil }
        return max(0, EntitlementPolicy.dailyFreeSeconds - todaySeconds)
    }

    /// 今天已听的秒数：每秒都在变，所以不发布，谁要谁现读
    private var todaySeconds: TimeInterval {
        guard UserDefaults.standard.string(forKey: EntitlementPolicy.usageDayKey)
                == EntitlementPolicy.dayKey(Date()) else { return 0 }
        return UserDefaults.standard.double(forKey: EntitlementPolicy.usageSecondsKey)
    }

    private init() {
        #if DEBUG
        unlockedForDevelopment = !UserDefaults.standard.bool(forKey: "SONUXDebugLocked")
        #else
        unlockedForDevelopment = false
        #endif
        if let stored = UserDefaults.standard.object(forKey: EntitlementPolicy.trialStartKey) as? Double {
            trialStart = Date(timeIntervalSince1970: stored)
        } else {
            trialStart = Date()
            UserDefaults.standard.set(trialStart.timeIntervalSince1970,
                                      forKey: EntitlementPolicy.trialStartKey)
        }
        let defaults = UserDefaults.standard
        isPurchased = defaults.bool(forKey: EntitlementPolicy.purchasedKey)
        isSubscribed = defaults.bool(forKey: EntitlementPolicy.subscribedKey)
        dailyCapReached = EntitlementPolicy.capReached(todaySeconds: todaySeconds)
        NSLog("[sonux] paywall: 试用起点 %.0f（%d 天前），买断 %@，订阅 %@，开发版放行 %@，Pro %@，今天已听 %.0f 秒",
              trialStart.timeIntervalSince1970,
              Int(Date().timeIntervalSince(trialStart) / (24 * 60 * 60)),
              isPurchased ? "是" : "否", isSubscribed ? "是" : "否",
              unlockedForDevelopment ? "是" : "否",
              isPro ? "是" : "否", todaySeconds)
        // 测试宿主里没有商店：取商品与回读交易都会卡在系统守护进程上，
        // 连带把主线程上走动的播放时钟一起拖住（真播放那几个用例会因此停住）。
        // 试用与计时判定不依赖商店，跳过回读不影响它们被验到
        if !Self.isRunningTests {
            listenForTransactions()
            Task { await self.refreshFromStore() }
        }
    }

    /// 跑在单元测试宿主里吗：XCTest 被装进来就是
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    #if DEBUG
    /// 测试用的裸实例：状态由入参定死，不读盘、不碰商店、不挂交易监听，也不吃开发版放行
    private init(trialStart: Date, purchased: Bool, subscribed: Bool = false) {
        self.trialStart = trialStart
        isPurchased = purchased
        isSubscribed = subscribed
        unlockedForDevelopment = false
        dailyCapReached = false
    }

    static func forTests(trialStart: Date, purchased: Bool = false,
                         subscribed: Bool = false) -> EntitlementService {
        EntitlementService(trialStart: trialStart, purchased: purchased, subscribed: subscribed)
    }

    /// 验收买断页用：`xcrun simctl launch booted com.kiwenlau.sonux --args -SONUXDebugPaywall 1`
    /// 直接把它拉起来，不必先把试用拨到过期、再手动点某个上锁的入口
    func showDebugPaywallIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "SONUXDebugPaywall") else { return }
        isPaywallPresented = true
    }
    #endif

    // MARK: - 闸门

    /// 只有 Pro 才放行的入口：语速、定时关闭、音量细调、跳过静音与语音增强
    func gatePro(_ action: @escaping () -> Void) {
        if isPro { action() } else { isPaywallPresented = true }
    }

    /// 试用期内也放行、到期上锁的入口：只有收听报告
    func gateReport(_ action: @escaping () -> Void) {
        if hasReportAccess { action() } else { isPaywallPresented = true }
    }

    // MARK: - 每日收听额度

    /// 记一笔真实收听秒数（播放器攒着随进度一起报，30 秒一笔）。
    /// 正好跨过上限时返回 true，调用方据此停下并把用户领去买断页
    @discardableResult
    func recordListening(_ seconds: TimeInterval) -> Bool {
        guard isMetered, seconds > 0 else { return false }
        let defaults = UserDefaults.standard
        let day = EntitlementPolicy.dayKey(Date())
        var accumulated = defaults.double(forKey: EntitlementPolicy.usageSecondsKey)
        if defaults.string(forKey: EntitlementPolicy.usageDayKey) != day {
            accumulated = 0   // 换天了：昨天那 30 分钟不结转
        }
        defaults.set(day, forKey: EntitlementPolicy.usageDayKey)
        accumulated += seconds
        defaults.set(accumulated, forKey: EntitlementPolicy.usageSecondsKey)
        let reached = EntitlementPolicy.capReached(todaySeconds: accumulated)
        defer { dailyCapReached = reached }
        return reached && !dailyCapReached
    }

    // MARK: - 商店

    /// 拉一次商品与手头已有的交易：启动时、进 Paywall 时都该是干净的
    func refreshFromStore() async {
        if lifetime == nil || monthly == nil {
            let found = (try? await Product.products(for: [EntitlementPolicy.lifetimeID,
                                                           EntitlementPolicy.monthlyID])) ?? []
            lifetime = found.first { $0.id == EntitlementPolicy.lifetimeID }
            monthly = found.first { $0.id == EntitlementPolicy.monthlyID }
        }
        var purchased = false
        var subscribed = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case EntitlementPolicy.lifetimeID:
                purchased = true
            case EntitlementPolicy.monthlyID:
                if transaction.expirationDate.map({ $0 > Date() }) ?? true { subscribed = true }
            default:
                break
            }
        }
        isPurchased = purchased
        isSubscribed = subscribed
    }

    /// 买断或订阅；系统自带的付款面板由 StoreKit 弹，这里只接结果
    func purchase(_ sku: Sku) async -> PurchaseOutcome {
        if lifetime == nil || monthly == nil {
            // 商店还没取到商品（离线、沙盒没配 StoreKit 文件）：与其让人干等一个没反应的按钮，
            // 先拉一次再试
            await refreshFromStore()
        }
        guard let product = sku == .lifetime ? lifetime : monthly else { return .failed }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return .failed }
                await transaction.finish()
                apply(transaction)
                return .purchased
            case .userCancelled:
                return .cancelled
            case .pending:
                // 家长审批、欠费这类要等系统那边点头的：此刻还没解锁，如实回失败
                return .failed
            @unknown default:
                return .failed
            }
        } catch {
            NSLog("[sonux] paywall: 购买出错 %@", error.localizedDescription)
            return .failed
        }
    }

    /// 两档商品，界面按这个决定点哪颗
    enum Sku: Hashable {
        case lifetime
        case monthly
    }

    /// 恢复购买：先把系统商店面板拉起来（换过 Apple ID 的人从这儿回来），再回读一遍手头的交易
    func restore() async -> PurchaseOutcome {
        try? await AppStore.sync()
        await refreshFromStore()
        return isPro ? .purchased : .failed
    }

    /// 系统在本机之外完成的交易（另一台设备买过、订阅续费、退款）会从这条流里冒出来
    private func listenForTransactions() {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result,
                      transaction.productID == EntitlementPolicy.lifetimeID
                        || transaction.productID == EntitlementPolicy.monthlyID else { continue }
                await transaction.finish()
                self?.apply(transaction)
            }
        }
    }

    /// 把一笔交易落到对应那档状态上；退款（revocationDate 有值）当场收回
    private func apply(_ transaction: Transaction) {
        let valid = transaction.revocationDate == nil
        switch transaction.productID {
        case EntitlementPolicy.lifetimeID:
            isPurchased = valid
        case EntitlementPolicy.monthlyID:
            isSubscribed = valid && (transaction.expirationDate.map { $0 > Date() } ?? true)
        default:
            break
        }
    }
}

/// 购买的结果：Paywall 只对失败说一句，取消与成功都只表现为界面状态变化
enum PurchaseOutcome: Equatable {
    case purchased
    case cancelled
    case failed
}
