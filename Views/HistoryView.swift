import SwiftUI

/// 播放历史页（参考微信听书「收听」）：每本书一张卡片，按最后播放时间从新到旧排列
/// 卡片 = 书名行（点击进详情页）+ 最后听到的章节 + 收听进度 + 右侧封面，点卡片其余区域从上次位置续播
struct HistoryView: View {
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var player: PlayerService
    /// 从历史页跳详情页：压进历史 tab 自己的导航栈，返回时回到历史页
    let onOpenBook: (String) -> Void

    var body: some View {
        let entries = library.historyEntries()
        Group {
            if entries.isEmpty {
                ContentUnavailableWrapper(
                    title: L("No Listening History Yet"),
                    systemImage: "clock.arrow.circlepath"
                ) { EmptyView() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(entries) { entry in
                            // 卡片不在 List 里，没有右滑删除，移除入口用长按菜单
                            HistoryCard(
                                entry: entry,
                                isNowPlaying: player.currentBook?.id == entry.book.id,
                                onOpenBook: { onOpenBook(entry.book.id) },
                                onPlay: { playFromLastPosition(entry) }
                            )
                            .contextMenu {
                                Button(role: .destructive) {
                                    NSLog("[sonux] ui: 长按菜单从历史移除《%@》", entry.book.title)
                                    library.removeFromHistory(bookId: entry.book.id)
                                } label: {
                                    Label(L("Remove from History"), systemImage: "trash")
                                }
                            }
                            .accessibilityIdentifier("history-card-\(entry.book.id)")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("History"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 从该书最后记录的位置开始播放，并打开全屏播放页（与书库的续播行为一致）
    private func playFromLastPosition(_ entry: LibraryService.HistoryEntry) {
        NSLog("[sonux] ui: 点击历史卡片播放《%@》", entry.book.title)
        player.play(book: entry.book, at: entry.position)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { player.showPlayer = true }
    }
}

/// 一张历史卡片：微信听书式布局——书名在上、章节名加粗、进度置底、封面居右
private struct HistoryCard: View {
    let entry: LibraryService.HistoryEntry
    /// 该书是否为当前播放的书（无论暂停与否）
    let isNowPlaying: Bool
    let onOpenBook: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // 书名行：独立 Button 才能保住自己的点击不被父层整卡手势合并，点它进详情页
                Button(action: onOpenBook) {
                    Text(entry.book.title)
                        .font(.subheadline)
                        .foregroundStyle(isNowPlaying ? Color.indigo : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-book-\(entry.book.id)")
                // 整卡是合并无障碍元素，AXPress 只会触发默认操作（续播）；给书名行单独挂命名操作
                .accessibilityAction(named: LF("Open Details for \"%@\"", entry.book.title)) { onOpenBook() }

                Text(entry.chapter?.title ?? entry.book.title)
                    .font(.title3.bold())
                    .foregroundStyle(isNowPlaying ? Color.indigo : Color.primary)
                    .lineLimit(2)

                Text(progressText)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)

                Text(relativeDay(entry.lastPlayed))
                    .font(.caption)
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .padding(.top, 2)
            }

            Spacer(minLength: 8)

            BookCoverView(book: entry.book)
                .overlay {
                    // 与书库列表行一致：封面右侧不另放按钮，续播入口由整卡点承担
                    if isNowPlaying {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.indigo, lineWidth: 2)
                    }
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 点卡片空白区域 = 从上次位置续播（书名行与封面自带手势，优先于父层）
        .onTapGesture(perform: onPlay)
        .accessibilityAction(named: LF("Play \"%@\" from Where You Left Off", entry.book.title)) { onPlay() }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isNowPlaying ? Color.indigo.opacity(0.1) : Color(.secondarySystemGroupedBackground))
        )
    }

    /// 进度文案：章节内位置 / 章节总时长
    private var progressText: String {
        guard let position = entry.position, let chapter = entry.chapter else { return L("Not Started") }
        if ProgressPolicy.isFinished(time: position.time, duration: chapter.duration) {
            return LF("Finished \"%@\"", chapter.title)
        }
        return "\(TimeFormat.time(position.time)) / \(TimeFormat.time(chapter.duration))"
    }

    /// 最后播放时间：今天/昨天/前天 加时刻，更早只给月日；日期格式跟随当前语言
    private func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        switch days {
        case 0: return LF("Today %@", time)
        case 1: return LF("Yesterday %@", time)
        case 2: return LF("Day Before Yesterday %@", time)
        default:
            let monthDay = date.formatted(.dateTime.month().day())
            return "\(monthDay) \(time)"
        }
    }
}
