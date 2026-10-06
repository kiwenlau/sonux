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
}

private struct NowPlayingProvider: TimelineProvider {
    /// 没在播时的兜底刷新间隔：内容不会自己变，留个很长的间隔等 App 来敲门
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

    /// 组件上没有会自己走的东西（不画进度条），所以一次只排一条：
    /// 换书、播停、切章都由 App 请系统刷新（见 WidgetSync），不必自己往外排一串时间点
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry],
                            policy: .after(entry.date.addingTimeInterval(Self.idleRefresh))))
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

/// 小号：整块封面铺满，底部压一层黑纱放书名与作者，左上角一枚播放标记
private struct SmallNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlayingBadge(isPlaying: entry.isPlaying, onCover: true)
            Spacer(minLength: 0)
            Text(entry.snapshot?.bookTitle ?? "")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let author = entry.snapshot?.author, !author.isEmpty {
                Text(author)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .widgetBackground {
            CoverBackdrop(cover: entry.cover, blurArt: !(entry.snapshot?.hasArtwork ?? false))
        }
    }
}

/// 中号：糊化的封面出血打底（与 App 底部面板一个做法），左边封面、右边书名作者章节名，
/// 右上角一枚播放标记
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
                    PlayingBadge(isPlaying: entry.isPlaying, onCover: false)
                }
                if let author = entry.snapshot?.author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(entry.snapshot?.chapterTitle ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

/// 播放标记：出声时画音柱，暂停时画播放三角。
/// 它只是状态标记，不是一枚按钮——音频只能由主 App 播，小组件（另一个进程）播不出声，
/// 整块组件点下去是回 App 的播放页
private struct PlayingBadge: View {
    let isPlaying: Bool
    /// 压在封面上时垫一层毛玻璃圆底（与书库卡片那枚播放键同一做法）：封面深浅不定，
    /// 不垫底细线条压上去就看不见
    var onCover: Bool

    private static let side: CGFloat = 20

    var body: some View {
        ZStack {
            if onCover {
                Circle().fill(.ultraThinMaterial)
                Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5)
            } else {
                Circle().fill(Color.indigo.opacity(0.12))
            }
            Image(systemName: isPlaying ? "waveform" : "play.fill")
                .font(.system(size: isPlaying ? 8 : 9, weight: .semibold))
                .foregroundStyle(onCover ? Color.white : Color.indigo)
                // 三角形重心偏左，往右挪一点才真正居中
                .offset(x: isPlaying ? 0 : 0.5)
        }
        .frame(width: Self.side, height: Self.side)
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
