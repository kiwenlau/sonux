import SwiftUI
import UIKit
import WidgetKit

/// 桌面小组件入口：Sonux 目前只有一个「正在收听」组件
@main
struct SonuxWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}

/// 「正在收听」小组件：把此刻在听的那本书摆到桌面，点一下回 App 的播放页接着听。
/// 数据来自 App 写进 App Group 的快照（见 WidgetBridge），进度靠快照时间戳往外推，
/// 因此不需要 App 在后台一遍遍请求刷新——小组件刷新是有日预算的。
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlayingWidget", provider: NowPlayingProvider()) { entry in
            NowPlayingView(entry: entry)
        }
        .configurationDisplayName("Sonux")
        .description("Now Playing")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 时间线条目与 provider

private struct NowPlayingEntry: TimelineEntry {
    let date: Date
    /// nil 表示还没听过任何东西（或共享数据被清了）
    let snapshot: NowPlayingSnapshot?
    let cover: UIImage?

    var isPlaying: Bool { snapshot?.isPlaying ?? false }
    var time: TimeInterval { snapshot?.time(at: date) ?? 0 }
    var duration: TimeInterval { snapshot?.duration ?? 0 }
    var remaining: TimeInterval { max(duration - time, 0) }
    var progress: Double { snapshot?.progress(at: date) ?? 0 }
}

private struct NowPlayingProvider: TimelineProvider {
    /// 播着时每条条目之间隔多久、往外排多久：一小时内的收听基本不用系统再问一次
    private static let step: TimeInterval = 30
    private static let span: TimeInterval = 20 * 60
    /// 没在播时的兜底刷新间隔：位置不会自己变，留个很长的间隔等 App 来敲门
    private static let idleRefresh: TimeInterval = 6 * 60 * 60

    /// 读共享数据拼一条「此刻」的条目
    private func currentEntry(at date: Date = Date()) -> NowPlayingEntry {
        NowPlayingEntry(date: date,
                        snapshot: WidgetBridge.readSnapshot(),
                        cover: WidgetBridge.readCover(maxPixel: 320))
    }

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .sample, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let snapshot = WidgetBridge.readSnapshot()
        let cover = WidgetBridge.readCover(maxPixel: 320)
        let now = Date()

        guard let snapshot, snapshot.isPlaying else {
            // 停着：位置不会再往前走，一条就够，等 App 播起来时请求刷新
            let entry = NowPlayingEntry(date: now, snapshot: snapshot, cover: cover)
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(Self.idleRefresh))))
            return
        }

        // 播着：每 30 秒排一条、往外排 20 分钟。进度由快照时间戳算出来（各条只差 date），
        // 所以小组件不用 App 在后台敲门也能一格一格往前走
        var entries: [NowPlayingEntry] = []
        var offset: TimeInterval = 0
        while offset <= Self.span {
            entries.append(NowPlayingEntry(date: now.addingTimeInterval(offset), snapshot: snapshot, cover: cover))
            offset += Self.step
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.span))))
    }
}

// MARK: - 界面

private struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        Group {
            if entry.snapshot == nil {
                NothingPlayingView()
            } else if family == .systemSmall {
                SmallNowPlayingView(entry: entry)
            } else {
                MediumNowPlayingView(entry: entry)
            }
        }
        .widgetURL(URL(string: "sonux://now-playing"))
    }
}

/// 小号：整块封面铺满，底部压一层黑纱放书名，最底一条进度
private struct SmallNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
            Text(entry.snapshot?.bookTitle ?? "")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            ProgressTrack(progress: entry.progress, fill: .white, track: .white.opacity(0.3))
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .widgetBackground {
            CoverBackdrop(cover: entry.cover, blurArt: !(entry.snapshot?.hasArtwork ?? false))
        }
    }
}

/// 中号：糊化的封面出血打底（与 App 底部面板一个做法），左边封面、右边书名章节名、底下一条进度
private struct MediumNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverThumb(cover: entry.cover, side: 68)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.snapshot?.bookTitle ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let snapshot = entry.snapshot, snapshot.chapterCount > 1 {
                        Text("\(snapshot.chapterIndex)/\(snapshot.chapterCount)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.snapshot?.chapterTitle ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                ProgressTrack(progress: entry.progress)
                HStack {
                    Text(TimeFormat.time(entry.time))
                    Spacer()
                    Text("-" + TimeFormat.time(entry.remaining))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBackground { BleedBackdrop(cover: entry.cover) }
    }
}

/// 空状态：只留图标与标题，不加说明文案
private struct NothingPlayingView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .medium))
            Text(L("Not Playing"))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetBackground { Color(.secondarySystemGroupedBackground) }
    }
}

/// 进度条：整条轨道 + 一段随进度增长的实心胶囊
private struct ProgressTrack: View {
    let progress: Double
    var fill: Color = .indigo
    var track: Color = Color.secondary.opacity(0.25)
    var height: CGFloat = 3

    var body: some View {
        Capsule()
            .fill(track)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(fill)
                        .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)), height: height)
                }
            }
            .accessibilityHidden(true)
    }
}

/// 封面缩略图：不铺底色，留白处露出所在背景（与 App 里的封面框同一套做法）
private struct CoverThumb: View {
    let cover: UIImage?
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.clear)
            .frame(width: side, height: side)
            .overlay {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: side * 0.34))
                        .foregroundStyle(.indigo)
                }
            }
    }
}

/// 小号的底：整张封面铺满 + 一层自下而上的黑纱，书名压在封面上也读得清
private struct CoverBackdrop: View {
    let cover: UIImage?
    /// 没有内嵌封面时那是按书名画的占位图：糊开只留颜色，免得和小组件自己那行书名重复成两行
    var blurArt: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.indigo.opacity(0.9), Color.indigo.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: blurArt ? 18 : 0)
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.62), location: 0),
                .init(color: .black.opacity(0.18), location: 0.45),
                .init(color: .clear, location: 0.8),
            ], startPoint: .bottom, endPoint: .top)
        }
        .accessibilityHidden(true)
    }
}

/// 中号的底：把封面糊开再压一层纱，只要颜色晕染、不要形状（App 底部面板的同款做法）
private struct BleedBackdrop: View {
    let cover: UIImage?

    var body: some View {
        ZStack {
            Color(.systemBackground)
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .overlay(Color(.systemBackground).opacity(0.55))
            }
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// 小组件整块底：iOS 17 起必须交给系统画（containerBackground，桌面长按还能出立体效果），
    /// 16 上没有这个 API，只能自己铺在内容后面
    @ViewBuilder
    func widgetBackground<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget, content: content)
        } else {
            background(content())
        }
    }
}
