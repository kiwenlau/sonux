import Foundation

/// App 的运行内核：书库 + 播放器这两个服务对象，以及把它们接在一起的进度记账。
///
/// 为什么把原来写在 SonuxApp 里的装配搬到这里：「嘿 Siri，播放我的书」走的是 App Intents，
/// 系统可能是把进程在后台拉起来执行意图的——那时没有场景、没有 RootView，`.task` 一辈子都不会跑。
/// 装配挂在界面上，语音开播就变成「装了个播放器，但没人给它记进度」。
/// 挪到这里之后谁先到谁装配（界面 `.task` 与意图都调 start()），只做一次。
@MainActor
final class SonuxRuntime {
    static let shared = SonuxRuntime()

    let library = LibraryService()
    let player = PlayerService()
    /// 装配只做一次的闸门
    private var didStart = false

    /// 冷启动装配：读上次扫描出的书库快照、接上进度与收听时长的记账、把最近收听的那本挂上。
    /// 重复调用直接返回；界面与语音入口都从这里进
    func start() {
        guard !didStart else { return }
        didStart = true
        library.bootstrap()
        wireProgressPersistence()
        restoreContinueListening()
    }

    /// 底部「继续收听」条常显：播放器里没挂书时（冷启动、播完、删书），
    /// 把最近收听的那本连进度一起挂上，不装载播放器也不抢音频焦点
    func restoreContinueListening() {
        let latest = library.historyEntries().first
        // 挂着没播的那本已被删掉，或扫描后又冒出更近收听的一本（外部引用的书不在冷启动快照里，
        // 要等后台扫描才回到书库）：先卸掉再挂对的这本
        if !player.hasPlayer, let prepared = player.currentBook, prepared.id != latest?.book.id {
            player.unloadPrepared()
        }
        guard !player.hasPlayer, player.currentBook == nil else { return }
        guard let entry = latest,
              let chapter = entry.chapter ?? entry.book.chapters.first else { return }
        player.prepareToResume(book: entry.book, chapter: chapter, at: entry.position?.time ?? 0)
    }

    /// 把播放器的进度回调接到书库持久化上
    private func wireProgressPersistence() {
        player.onPositionChange = { [weak library, weak player] position in
            guard let library, let bookId = player?.currentBook?.id else { return }
            library.recordPosition(position, bookId: bookId)
        }
        // 自动续播下一章时，查询该章节自己的历史播放位置
        player.chapterHistory = { [weak library] chapterId in
            library?.position(forChapter: chapterId)
        }
        // 收听时长累加：同一秒内紧跟着的 recordPosition 会把统计一起落盘
        player.onListening = { [weak library] seconds, bookId in
            library?.addListening(seconds: seconds, bookId: bookId)
        }
    }

    // MARK: - 语音入口（App Intents 走这里，调试钩子也走这里）

    /// 播一本书：报得出书名就播那本，没报就接着上次听的那本。
    /// 手上正是这本且已装载好音频时只续播——「播放我的书」不该把人正在听的那句从头再来
    @discardableResult
    func playForVoice(bookId: String?) throws -> Book {
        start()
        let book: Book
        if let bookId {
            guard let found = library.book(id: bookId) else {
                NSLog("[sonux] voice: 书库里找不到 id=%@ 的书", bookId)
                throw SonuxVoiceError.missingBook
            }
            book = found
        } else if let latest = library.historyEntries().first?.book {
            book = latest
        } else if let next = library.nextUnfinishedBook() {
            book = next
        } else {
            NSLog("[sonux] voice: 书库里没有书（%d 本），没什么可播", library.books.count)
            throw SonuxVoiceError.emptyLibrary
        }

        if player.currentBook?.id == book.id, player.hasPlayer {
            player.resumePlayback()
            NSLog("[sonux] voice: 续播手上的《%@》", book.title)
            return book
        }
        player.play(book: book, at: library.position(forBook: book.id))
        NSLog("[sonux] voice: 开播《%@》", book.title)
        return book
    }

    /// 切章：+1 下一章、-1 上一章。手上没挂书时切章没有意义（连要往下走哪本都不知道）
    @discardableResult
    func advanceChapterForVoice(by offset: Int) throws -> Chapter {
        start()
        guard let chapter = player.currentChapter, offset != 0 else {
            NSLog("[sonux] voice: 手上没有正在听的书，切章就此打住")
            throw SonuxVoiceError.nothingPlaying
        }
        if offset > 0 { player.nextChapter() } else { player.previousChapter() }
        let landed = player.currentChapter ?? chapter
        NSLog("[sonux] voice: 切到《%@》", landed.title)
        return landed
    }

    #if DEBUG
    /// 语音入口的调试钩子：用启动参数把一条意图原样跑一遍。模拟器里没有 Siri，快捷指令也自动化不了，
    /// 想验收「说句话就出声」这条链就从启动参数进到这里——跑的仍是意图本体，只跳过 Siri 那一跳。
    ///
    ///   xcrun simctl terminate booted com.kiwenlau.sonux
    ///   xcrun simctl launch booted com.kiwenlau.sonux --args -SONUXDebugIntent play
    func runDebugIntentIfNeeded() async {
        guard let name = UserDefaults.standard.string(forKey: "SONUXDebugIntent") else { return }
        NSLog("[sonux] voice: 调试钩子执行意图 %@", name)
        do {
            switch name {
            case "play": _ = try await PlayBookIntent().perform()
            case "playFirst":
                let intent = PlayBookIntent()
                intent.book = library.books.first.map { BookEntity(id: $0.id, title: $0.title) }
                _ = try await intent.perform()
            case "next": _ = try await NextChapterIntent().perform()
            case "previous": _ = try await PreviousChapterIntent().perform()
            default: NSLog("[sonux] voice: 调试钩子不认识这个动作 %@", name)
            }
        } catch {
            NSLog("[sonux] voice: 调试意图失败 %@", error.localizedDescription)
        }
    }
    #endif
}

/// 语音入口办不成事时的那几句话：会被 Siri 念出来，所以得是人能听懂的理由
enum SonuxVoiceError: LocalizedError {
    case emptyLibrary
    case missingBook
    case nothingPlaying

    var errorDescription: String? {
        switch self {
        case .emptyLibrary: return L("Your library is empty.")
        case .missingBook: return L("I couldn’t find that book in Sonux.")
        case .nothingPlaying: return L("Nothing is playing in Sonux yet.")
        }
    }
}
