import SwiftUI

/// 买断页：免费与 Pro 两列对照 + 月订阅做价格锚，主按钮留给永久买断。
/// 价格一律取自商店的 `Product.displayPrice`，界面不写死金额——换区、调价、含税都跟着走
///
/// 表里只摆「买了就一定拿得到」的：时长、播放控制、语音增强、收听报告。字幕那一类
/// 不写——它要求该书有字幕文件，而首版不给用户提供拿到字幕的办法，
/// 写在付费表里就是拿开发环境里跑得通的东西去卖一个买不到的能力。
struct PaywallView: View {
    @ObservedObject private var entitlement = EntitlementService.shared
    @Environment(\.dismiss) private var dismiss
    /// 哪一颗按钮正在等商店回话；两颗都不许再点
    @State private var working: EntitlementService.Sku?

    /// 订阅界面必须挂出条款与隐私政策（审核 3.1.2）。条款用 Apple 标准 EULA；
    /// 隐私政策要等 URL 定下来再补一行
    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L("Sonux Pro"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.indigo)

                    ComparisonTable(rows: rows)

                    if entitlement.isPro {
                        Text(L("Unlocked"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.indigo)
                    } else {
                        purchaseButtons
                    }

                    footnotes
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel(L("Back"))
                }
            }
        }
        .tint(.indigo)
        .accessibilityIdentifier("paywall-page")
        // 每次打开都回读一次商店：别的设备买过、上次没拉下来的价格，都该在这儿补上；
        // 上次失败的提示不留到这一次
        .task {
            entitlement.purchaseFailed = false
            await entitlement.refreshFromStore()
        }
    }

    // MARK: - 对照表

    /// 一行一项权益：免费那列给「30 分钟 / 试用 7 天 / 没有」，Pro 那列给「不限 / 有」。
    /// 不私有是因为测试要照着它验「表里不许摆用户买不到的能力」（见 EntitlementGateTests）
    var rows: [ComparisonRow] {
        let trial = LF("%d-Day Trial", Int(EntitlementPolicy.trialDuration / (24 * 60 * 60)))
        return [
            ComparisonRow(feature: L("Listening Time"),
                          free: .text(LF("%d Minutes a Day",
                                         Int(EntitlementPolicy.dailyFreeSeconds / 60))),
                          pro: .text(L("Unlimited"))),
            ComparisonRow(feature: L("Speed, Volume & Sleep Timer"), free: .none, pro: .yes),
            ComparisonRow(feature: L("Voice Boost"), free: .none, pro: .yes),
            ComparisonRow(feature: L("Listening Report"), free: .text(trial), pro: .yes),
        ]
    }

    // MARK: - 两档商品

    private var purchaseButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { buy(.lifetime) } label: {
                buttonLabel(lifetimeLabel, filled: true)
            }
            .accessibilityIdentifier("paywall-buy-lifetime")

            Button { buy(.monthly) } label: {
                buttonLabel(monthlyLabel, filled: false)
            }
            .accessibilityIdentifier("paywall-buy-monthly")

            // 自动续订必须把「按月扣、随时能退」说在明面上：这是审核要求，也是不搞套路的底线
            Text(L("Renews monthly — cancel anytime in Settings."))
                .font(.caption)
                .foregroundStyle(.secondary)

            // 买断等于几个月的订阅，算给用户看：用得上就一次买断，用不久就按月
            if let months = monthsPerPurchase {
                Text(LF("One Payment = %d Months", months))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(working != nil)
    }

    private var lifetimeLabel: String {
        if let price = entitlement.lifetime?.displayPrice { return LF("Unlock Everything — %@", price) }
        return L("Unlock")
    }

    private var monthlyLabel: String {
        guard let price = entitlement.monthly?.displayPrice else { return L("Monthly Subscription") }
        return LF("%@ per month", price)
    }

    /// 买断价对月订阅价的整数倍；两件商品没齐或倍数不到两倍就别比（比了反而掉价）
    private var monthsPerPurchase: Int? {
        guard let lifetime = entitlement.lifetime, let monthly = entitlement.monthly else { return nil }
        let ratio = (lifetime.price as NSDecimalNumber)
            .dividing(by: monthly.price as NSDecimalNumber).doubleValue
        guard ratio >= 2 else { return nil }
        return Int(ratio.rounded(.down))
    }

    private func buttonLabel(_ text: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            if working != nil {
                ProgressView().tint(filled ? .white : .indigo)
            }
            Text(text)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(filled ? Color.indigo : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(filled ? Color.clear : Color.indigo, lineWidth: 1))
                .foregroundStyle(filled ? Color.white : Color.indigo)
        }
    }

    private func buy(_ sku: EntitlementService.Sku) {
        working = sku
        Task {
            defer { working = nil }
            switch await entitlement.purchase(sku) {
            case .purchased:
                dismiss()
            case .cancelled:
                break
            case .failed:
                entitlement.purchaseFailed = true
            }
        }
    }

    // MARK: - 尾巴

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entitlement.dailyCapReached {
                Text(L("Today’s Free Listening Time Is Used Up"))
                    .font(.footnote)
                    .foregroundStyle(Color.indigo)
            }
            if entitlement.purchaseFailed {
                Text(L("That purchase didn’t go through. Try again or restore."))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let left = entitlement.trialDaysLeft {
                Text(LF("Trial ends in %d days", left))
            }
            HStack(spacing: 16) {
                Button(L("Restore Purchases")) { Task { await restore() } }
                Link(L("Terms of Use"), destination: Self.termsURL)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func restore() async {
        entitlement.purchaseFailed = false
        if await entitlement.restore() == .purchased { dismiss() }
    }
}

// MARK: - 两列对照

/// 一行权益：免费列与 Pro 列各一格
struct ComparisonRow {
    enum Cell {
        case none
        case yes
        case text(String)
    }

    let feature: String
    let free: Cell
    let pro: Cell
}

/// 免费 / Pro 两列对照表：左列权益名占满剩余宽度，两列各 56pt 居中
private struct ComparisonTable: View {
    let rows: [ComparisonRow]

    /// 两列的固定宽度：按最长的那格文案（中文「每天 30 分钟」）定的，列头与格子才对得齐
    private static let columnWidth: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.feature)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(row.free)
                    cell(row.pro)
                }
            }
        }
        .accessibilityIdentifier("paywall-comparison")
    }

    private var header: some View {
        HStack(spacing: 8) {
            // 权益名那一列不给表头，留空位把两列的列头顶到该在的地方
            Color.clear
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Free"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.columnWidth)
            Text(L("Sonux Pro"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.indigo)
                .frame(width: Self.columnWidth)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cell(_ cell: ComparisonRow.Cell) -> some View {
        Group {
            switch cell {
            case .none:
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            case .yes:
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.indigo)
            case .text(let value):
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.columnWidth)
    }
}
