import Foundation
import AVFoundation
import MediaPlayer
import QuartzCore
import Combine

/// 定时关闭模式：分钟数可在滑动条范围内任意设置，也可在听完 N 章之后关闭
enum SleepTimerMode: Equatable {
    case off
    case minutes(Int)
    /// 听完 N 章后关闭，1 章就是「本章结束后关闭」。挂章睡的人不肯在章中途被拦停，
    /// 所以它不计时长，只在每一章真播完的那一刻减一格
    case chapters(Int)

    /// 分钟轴的范围：0–90，一格 1 分钟
    static let range: ClosedRange<Double> = 0...90
    /// 章数轴的范围：1–5 章，再多就等于没定时。轴固定画到 5，不随剩下的章数伸缩
    static let chapterRange: ClosedRange<Int> = 1...5
}

/// 播放服务：基于 AVPlayer，负责播放、进度回调、锁屏控制与定时关闭
@MainActor
final class PlayerService: NSObject, ObservableObject {
    // 当前播放状态
    @Published private(set) var currentBook: Book?
    @Published private(set) var currentChapter: Chapter?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var speed: Float = 1.0
    /// 是否展示全屏播放界面（点列表播放时直接打开）
    @Published var showPlayer = false
    // 定时关闭
    @Published private(set) var sleepMode: SleepTimerMode = .off

    /// 每秒走动的读数：单独一个观察对象，只让跟着秒跳的界面盯着它。
    /// 挂在这个对象的 @Published 上会让每一页每秒重算一次 body，见 PlaybackClock
    let clock = PlaybackClock()

    /// 本章内已播秒。界面要跟着它跳，请观察 `clock`，读值走这里
    var currentTime: TimeInterval { clock.currentTime }

    /// 分钟定时的剩余秒表：存在时钟里，每秒一跳由它自己发布
    private var sleepRemaining: TimeInterval {
        get { clock.sleepRemaining }
        set { clock.setSleepRemaining(newValue) }
    }

    var onChapterFinished: ((Chapter, Book) -> Void)?
    /// 进度上报（播完一章、暂停、停止、拖过进度都当场报一次，播放中每 30 秒一次，见 accountProgress）
    var onPositionChange: ((PlayPosition) -> Void)?
    /// 查询某章节的历史播放位置（自动续播到下一章时使用）
    var chapterHistory: ((String) -> PlayPosition?)?
    /// 收听时长上报：这一段真实收听了多少墙钟秒（倍速不放大，暂停与挂起的空档不计入）。
    /// 播放器先攒着，跟着下一次进度上报一起报，不每秒惊动一次统计与落盘
    var onListening: ((TimeInterval, String) -> Void)?

    /// 上次计时的时间点：只在播放中累加，暂停/停止时清空
    private var listeningAnchor: Date?

    // MARK: - 进度结账的节流（书库记账 + 落盘）

    /// 结账间隔：播放中每这么久才向书库记一次位置与收听秒数，也就每这么久落一次盘。
    /// 每秒一次全量 JSON 编码 + .atomic 写盘，在真机 1300+ 章上是每小时往闪存写 400 MB；
    /// 而界面那格读数由 PlaybackClock 每秒发布，不依赖这一笔。
    /// nonisolated：它是下面那条静态判据的默认量程
    nonisolated static let progressAccountingInterval: TimeInterval = 30
    /// 还没结进书库的收听秒数：攒到下一次结账一起报，免得每秒惊动一次统计与落盘
    private var pendingListeningSeconds: TimeInterval = 0
    /// 上一次结账的时刻：节流窗口从这一刻起算
    private var lastAccountedAt: Date?
    /// 上一次结进书库的位置：与手上的读数一样就说明没账可结
    private var lastAccountedPosition: PlayPosition?

    /// 播放器实例常驻，换章节只换 item：AVPlayer 是边播边解，
    /// 十几小时一本的 m4b 不再像 AVAudioPlayer 那样把整本解码进内存
    private var player: AVPlayer?
    /// 当前装载进播放器的音频文件：内嵌章节的书多章共用一个文件，用它判断能否原地跳章
    private var loadedFileURL: URL?
    /// 当前 item 的失败监听与播完通知：换 item 时整体重建
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?
    private var itemFailObserver: NSObjectProtocol?
    /// 播放状态监听：AVPlayer 会自己停（播完、出错、会话被系统收回），
    /// isPlaying 必须跟着它，不能只跟着按钮
    private var timeControlObservation: NSKeyValueObservation?
    /// 精确 seek 的代次：完成回调可能在又一次 seek 或切章之后才回来，只认最后发出的那一次
    private var seekGeneration = 0
    /// 最近一次发出精确 seek 的时刻：不为 nil 说明还没落地。期间播放器报的时间可能仍是
    /// 上一段的，别拿它写章进度或判章尾
    private var seekIssuedAt: Date?
    /// seek 落地等待上限：换 item 会取消挂起的 seek，回调不一定按约定回来，
    /// 超过这段时间就当前提它已落地，免得进度与续章永久停更
    private static let seekSettleTimeout: TimeInterval = 2
    private var displayLinkTimer: Timer?
    private var sleepTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// 被打断前是否处于播放状态（用于中断结束后自动恢复）
    private var wasPlayingBeforeInterruption = false
    /// 最后一次出声 / 用户刚摆正位置的时刻：续播时用它算停了多久，停够久才回退
    private var lastAudibleAt: Date?
    /// 停播超过这么久再续播才回退：随手暂停马上继续（回个消息、想重听一句）不该被往回拽
    private static let resumeRewindAfter: TimeInterval = 30
    /// 章尾判定余量：内嵌章节的书靠计时发现「到章尾了」，差这一点就算播完，
    /// 免得把上一章的最后一帧算成下一章的开头
    private static let chapterEndTolerance: TimeInterval = 0.05
    /// 音频会话是否已激活过：setCategory/setActive 是同步阻塞调用，激活过一次就别每次点播放都重跑
    private var audioSessionActivated = false
    /// 连续语速范围与步进：0.5x–3x，每格 0.1
    static let speedRange: ClosedRange<Double> = 0.5...3.0
    static let speedStep: Double = 0.1
    /// 限制在语速范围内并对齐到 0.1 步进，避免浮点误差累积
    private static func normalizedSpeed(_ value: Float) -> Float {
        let clamped = min(max(value, Float(speedRange.lowerBound)), Float(speedRange.upperBound))
        return (clamped * 10).rounded() / 10
    }
    /// 秒与 CMTime 往返回采用的刻度：600 能整除常见音频时间基，换算不丢精度
    private static let timescale: Int32 = 600

    // MARK: - 跳过静音 / 语音增强的记账

    /// 静音地图的缓存：键是章节 id。字幕整本一次读进来，逐章的空档表没必要每次重算
    private var silenceGaps: [String: [SilenceGap]] = [:]
    /// 这份地图属于哪本书：换书必须整份丢掉，否则章 id 撞上就拿着旧地图跳
    private var silenceGapsBookId: String?
    /// 本次播放累计跳过的音频秒数：跳过静音的全部意义就是这个数字，日志里要说清
    private var silenceSkipped: TimeInterval = 0
    /// 音轨 id 缓存：混音上的处理链要指名挂到哪条音轨，问资产要音轨是异步的，别每章都问
    private var audioTrackIDs: [URL: CMPersistentTrackID] = [:]
    /// 已经问过音轨 id 的文件：问不到就不重复问，免得每章都开一次资产
    private var trackLookupTried: Set<URL> = []
    /// 进度计时走了多少格：语音增强的处理链每 10 格报一次心跳
    private var progressTicks = 0

    // MARK: - 定时关闭记忆（参考微信读书：下次播放自动沿用上次设置）

    /// 分钟定时全库只记一份：它数的是墙钟时间，跟听的是哪本书无关
    private static let lastSleepModeKey = "sleepTimer.lastMode"
    private static let lastSleepMinutesKey = "sleepTimer.lastMinutes"
    /// 章数定时一本书记一份：键是 bookId，值是章数。章节长短每本都不一样，
    /// 「听完 2 章」在一本书是 20 分钟、在另一本是 50 分钟，共用一个数哪本都对不上
    private static let sleepChaptersByBookKey = "sleepTimer.chaptersByBook"

    /// 记住的分钟定时（定时自然到期不清除，用户主动关掉才清除）：下次出声时按它满额重计
    private var rememberedSleepMode: SleepTimerMode? {
        switch UserDefaults.standard.integer(forKey: Self.lastSleepModeKey) {
        case 1:
            let minutes = UserDefaults.standard.integer(forKey: Self.lastSleepMinutesKey)
            return minutes > 0 ? .minutes(minutes) : nil
        default:
            // 「听完 N 章」不跨播放沿用：当初那几章早就听完了，
            // 沿用会让之后每次播放都在 N 章后停，分钟定时形同失效
            return nil
        }
    }

    /// 这本书「听完 N 章」卡片下次给的章数：只当默认值，不自动生效（沿用规则见上）
    var defaultSleepChapters: Int {
        guard let bookId = currentBook?.id else { return 1 }
        let store = UserDefaults.standard.dictionary(forKey: Self.sleepChaptersByBookKey)
        let stored = (store?[bookId] as? NSNumber)?.intValue ?? 1
        return SleepTimerMode.chapterRange.contains(stored) ? stored : 1
    }

    /// 仅记录用户主动选择的模式（定时自然到期不清除记忆）
    private func rememberSleepMode(_ mode: SleepTimerMode) {
        switch mode {
        case .off:
            UserDefaults.standard.set(0, forKey: Self.lastSleepModeKey)
        case .minutes(let minutes):
            UserDefaults.standard.set(1, forKey: Self.lastSleepModeKey)
            UserDefaults.standard.set(minutes, forKey: Self.lastSleepMinutesKey)
        case .chapters(let count):
            // 记下「这次选的是章数」：否则下次播放会把上上次的分钟定时又自动开起来
            UserDefaults.standard.set(2, forKey: Self.lastSleepModeKey)
            // 章数记在这本书名下。定时面板只在播放页打开，手上没书时没什么可记
            guard let bookId = currentBook?.id else { return }
            var store = UserDefaults.standard.dictionary(forKey: Self.sleepChaptersByBookKey) ?? [:]
            store[bookId] = count
            UserDefaults.standard.set(store, forKey: Self.sleepChaptersByBookKey)
        }
    }

    /// 停下时未走完的定时（停止时保留剩余时间，恢复播放时接着走）
    private var pendingSleepMode: SleepTimerMode?
    private var pendingSleepRemaining: TimeInterval = 0

    // MARK: - 每本书的倍速记忆（小说和商书想要的速度不一样）

    /// 一本书一个速度：字典键是 bookId，值是倍速。全库几十本书，合成一个键存就够了
    private static let speedByBookKey = "playback.speedByBook"

    /// 这本书上次用的倍速；没设置过的书从 1.0 起
    private static func rememberedSpeed(forBook bookId: String) -> Float {
        guard let stored = UserDefaults.standard.dictionary(forKey: speedByBookKey)?[bookId] as? NSNumber else {
            return 1.0
        }
        return normalizedSpeed(stored.floatValue)
    }

    /// 把倍速记在当前这本书名下。倍速只在播放页改，手上没书时没什么可记
    private static func remember(speed: Float, forBook bookId: String?) {
        guard let bookId else { return }
        var store = UserDefaults.standard.dictionary(forKey: speedByBookKey) ?? [:]
        store[bookId] = speed
        UserDefaults.standard.set(store, forKey: speedByBookKey)
    }

    /// 丢掉已删除书籍的倍速记忆
    func forgetSpeed(bookId: String) {
        var store = UserDefaults.standard.dictionary(forKey: Self.speedByBookKey) ?? [:]
        guard store[bookId] != nil else { return }
        store[bookId] = nil
        UserDefaults.standard.set(store, forKey: Self.speedByBookKey)
    }

    override init() {
        super.init()
        setupRemoteCommands()
        observeInterruptions()
        observeRouteChanges()
        observePlaybackSettings()
    }

    // MARK: - 播放控制

    /// 从指定位置开始播放一本书
    func play(book: Book, at position: PlayPosition?) {
        guard let chapter = chapter(in: book, for: position) ?? book.chapters.first else { return }
        let time = positionTime(in: book, chapter: chapter, position: position)
        play(chapter: chapter, book: book, fromTime: time)
    }

    /// 播放某一章节。fromTime 与对外发布的 currentTime 都是「本章内」的秒；
    /// 内嵌章节的 m4b 里本章只是文件的一段，落到播放器上要换算成文件内的秒
    func play(chapter: Chapter, book: Book, fromTime: TimeInterval = 0) {
        activateAudioSession()
        let local = clampedLocalTime(fromTime, in: chapter)
        // 换章/换书前先把上一段结清：位置与攒下的收听秒数当场落盘。
        // 不结的话下一笔要等 30 秒的节流窗口，回头续播会把人退回最多 30 秒
        if currentChapter != nil, currentChapter?.id != chapter.id || currentBook?.id != book.id {
            accountProgress(force: true)
        }
        // 换书时摘掉上一本的章数定时：那几章是上一本要听的量，这本书章节长短不同，
        // 接着数会在完全对不上的时长上停。分钟定时不摘，它数的是墙钟时间，听哪本都算
        if currentBook?.id != book.id, case .chapters = sleepMode { clearSleepTimer() }
        currentBook = book
        currentChapter = chapter
        // 倍速跟着书走：先换成这本书自己记着的速度，下面才按它出声
        speed = Self.rememberedSpeed(forBook: book.id)
        duration = chapter.duration
        clock.setCurrentTime(local)
        // 新的一章重新起账：下一格计时就把「正在听这本」记进历史，不等节流窗口
        lastAccountedPosition = nil
        lastAccountedAt = nil

        // 同一文件内的章节切换：只跳个偏移就出声。换了文件才重装 item——
        // 一本十几小时的书若每次切章都重开文件，就要重新解析索引、重建解码器，又慢又吃内存
        if hasPlayer, loadedFileURL == chapter.fileURL {
            playAtFileTime(chapter.fileTime(local))
            return
        }
        loadItem(for: chapter, atFileTime: chapter.fileTime(local))
    }

    /// 装载本章所在的文件并从给定秒出声。倍速质量是这次换 AVPlayer 的直接收益：
    /// item 上的 audioTimePitchAlgorithm 能选频谱算法（变速不变调），
    /// AVAudioPlayer 的 rate 只能连音高一起拔高
    private func loadItem(for chapter: Chapter, atFileTime seconds: TimeInterval) {
        let item = AVPlayerItem(url: chapter.fileURL)
        item.audioTimePitchAlgorithm = .spectral
        attachVoiceBoost(to: item, for: chapter.fileURL)
        watch(item)
        ensurePlayer().replaceCurrentItem(with: item)
        loadedFileURL = chapter.fileURL
        playAtFileTime(seconds)
    }

    /// 播放器实例只用一个：重建实例要重新连接输出与解码链路，代价白花
    private func ensurePlayer() -> AVPlayer {
        if let player { return player }
        let player = AVPlayer()
        // 播到文件结尾就停住（不循环、不自动往前），由 didPlayToEnd 决定续哪一章
        player.actionAtItemEnd = .pause
        self.player = player
        observeTimeControl(of: player)
        return player
    }

    /// 定位到文件内某秒并按当前倍速出声。不能用 play()：它把 rate 钉回 1.0，
    /// 倍速会被悄悄抹掉
    private func playAtFileTime(_ seconds: TimeInterval) {
        seekPrecise(toFileTime: seconds)
        player?.rate = speedValue()
        isPlaying = true
        markPlaybackStarted()
    }

    /// 章内秒的合法区间：结尾留半秒余量，免得刚设位置就被判成播完
    private func clampedLocalTime(_ time: TimeInterval, in chapter: Chapter) -> TimeInterval {
        min(max(0, time), max(chapter.duration - 0.5, 0))
    }

    /// 出声之后要办的事：进度计时、续播回退基准、收听计时、定时关闭接续、锁屏信息
    private func markPlaybackStarted() {
        startProgressTimer()
        touchResumeClock()
        listeningAnchor = Date()
        applyRememberedSleepTimerIfNeeded()
        updateNowPlaying()
    }

    /// 这次出声该挂上哪个定时、从多少秒起走：
    /// - 定时还没走完就被停掉（停止后又重播）→ 接着剩下的时间走，不重新满额计时
    /// - 手上没有待走完的剩余（定时已归零、或杀进程重开）→ 沿用记忆的分钟数满额重计
    /// - 用户主动关过定时就没有记忆可沿用，返回 nil 什么都不开
    /// 章数定时不在这里出现：它只在章界兑现，不跨播放沿用（见 rememberedSleepMode）
    var sleepTimerToApply: (mode: SleepTimerMode, from: TimeInterval)? {
        guard sleepMode == .off else { return nil }
        if let mode = pendingSleepMode, pendingSleepRemaining > 0 { return (mode, pendingSleepRemaining) }
        guard case .minutes(let minutes) = rememberedSleepMode else { return nil }
        return (.minutes(minutes), TimeInterval(minutes * 60))
    }

    /// 出声时把该挂的定时挂上：规则见 sleepTimerToApply，这里只管起表
    private func applyRememberedSleepTimerIfNeeded() {
        guard isPlaying, let (mode, from) = sleepTimerToApply else { return }
        pendingSleepMode = nil
        pendingSleepRemaining = 0
        if case .minutes(let minutes) = mode {
            NSLog("[sonux] sleepTimer: 本次播放挂上 %d 分钟定时，从 %.0f s 起走", minutes, from)
        }
        resumeSleepTimer(mode: mode, remaining: from)
    }

    /// 停了再续播时往回退几秒：中断恢复、锁屏播放、切回 App 后人接不上刚才的话
    /// 停够久才退（随手暂停又继续不该被往回拽），章头几秒不再退
    /// 只改播放起点，不把回退后的位置写回进度，免得反复续播把位置越退越靠前
    private func rewindAfterPauseIfNeeded() {
        guard let player, player.timeControlStatus == .paused, let chapter = currentChapter else { return }
        let pausedFor = lastAudibleAt.map { Date().timeIntervalSince($0) } ?? .infinity
        // 章内秒才可比：回退不能退到本章起点之前（那是上一章的地盘）
        let local = chapter.localTime(fileTimeNow)
        guard pausedFor >= Self.resumeRewindAfter, local > ProgressPolicy.resumeRewind else { return }
        let target = local - ProgressPolicy.resumeRewind
        seekPrecise(toFileTime: chapter.fileTime(target))
        clock.setCurrentTime(target)
        NSLog("[sonux] resume: 已停 %.0f s，续播回退到《%@》%.0f s", min(pausedFor, 86400), chapter.title, target)
    }

    /// 更新续播回退的计时基准：正在出声，或用户刚把位置摆正（拖进度、快进快退）
    private func touchResumeClock() {
        lastAudibleAt = Date()
    }

    func togglePlayPause() {
        let t0 = CACurrentMediaTime()
        NSLog("[sonux] togglePlayPause: begin isPlaying=%d", isPlaying ? 1 : 0)
        guard let player = player, player.currentItem != nil else {
            NSLog("[sonux] togglePlayPause: no player, replay book")
            if let book = currentBook { play(book: book, at: currentPosition()) }
            return
        }
        // 缓冲中（waiting）也算「用户要听」，按一下就停；只有真停住了才走续播
        if player.timeControlStatus != .paused {
            player.pause()
            isPlaying = false
            NSLog("[sonux] togglePlayPause: paused %.1f ms", (CACurrentMediaTime() - t0) * 1000)
        } else {
            activateAudioSession()
            rewindAfterPauseIfNeeded()
            player.rate = speed // 暂停期间调整的倍速需重新应用；不能用 play()，它会把 rate 钉回 1.0
            isPlaying = true
            touchResumeClock()
            applyRememberedSleepTimerIfNeeded()
            NSLog("[sonux] togglePlayPause: resumed %.1f ms", (CACurrentMediaTime() - t0) * 1000)
        }
        updateNowPlaying()
        NSLog("[sonux] togglePlayPause: done total %.1f ms", (CACurrentMediaTime() - t0) * 1000)
    }

    /// 跳到本章内的某个秒数：进度条、快进快退、锁屏拖动都按章内位置算，
    /// 落到播放器上再换算成文件内的秒
    func seek(to time: TimeInterval) {
        let chapter = currentChapter
        let span = chapter?.duration ?? duration
        let clamped = min(max(0, time), span)
        clock.setCurrentTime(clamped)
        // 手动拖过位置就说明人知道自己在听哪儿，这段停顿不再当作「接不上话」处理
        touchResumeClock()
        accountProgress(force: true)
        guard let player = player, player.currentItem != nil else {
            // 只挂了位置没装载音频：记下目标时间，按播放键就从这里出声
            return
        }
        seekPrecise(toFileTime: chapter.map { $0.fileTime(clamped) } ?? clamped)
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func nextChapter() {
        advance(by: 1)
    }

    func previousChapter() {
        // 播放超过 3 秒时，上一首先回到本章开头
        if currentTime > ProgressPolicy.epsilon {
            seek(to: 0)
            return
        }
        advance(by: -1)
    }

    private func advance(by offset: Int) {
        guard let book = currentBook, let chapter = currentChapter,
              let idx = book.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
        let target = idx + offset
        guard book.chapters.indices.contains(target) else {
            if offset > 0 { stop() }
            return
        }
        let next = book.chapters[target]
        // 下一章若有未播完的历史位置，则从该位置续播
        play(chapter: next, book: book, fromTime: resumeTime(for: next))
    }

    func setSpeed(_ value: Float) {
        let rounded = Self.normalizedSpeed(value)
        speed = rounded
        // 只给「已经要出声」的播放器改速率：AVPlayer 一给非 0 的 rate 就真播了，
        // 拖着倍速滑杆会把暂停着的书悄悄放出来
        if let player, player.rate != 0 {
            player.rate = rounded
        }
        // 记在这本书名下：下次回到它自动用自己的速度，不受别的书影响
        Self.remember(speed: rounded, forBook: currentBook?.id)
        updateNowPlaying()
    }

    /// 是否已装载音频（真能出声）：false 时只是挂着收听位置
    var hasPlayer: Bool { player?.currentItem != nil }

    /// 把某本书的收听位置挂上但不播放：供常显的「继续收听」条使用。
    /// 不创建 AVPlayerItem、也不激活音频会话——按播放键才真正出声，
    /// 冷启动打开 App 因此不会抢走用户正在别的 App 里听的音乐
    func prepareToResume(book: Book, chapter: Chapter, at time: TimeInterval) {
        guard !hasPlayer else { return }
        currentBook = book
        currentChapter = chapter
        // 挂着没出声也要把倍速摆成这本书的：播放页显示的就得是按下播放键后会用的速度
        speed = Self.rememberedSpeed(forBook: book.id)
        duration = chapter.duration
        clock.setCurrentTime(min(max(0, time), max(chapter.duration, 0)))
        isPlaying = false
        // 冷启动时小组件也该知道在听哪本：这条状态不会走 updateNowPlaying（没出声），单独报一次
        syncWidget(book: book, chapter: chapter)
    }

    /// 卸掉挂着但未播放的那本书（书被删掉时调用）；正在播放的不受影响
    func unloadPrepared() {
        guard !hasPlayer else { return }
        currentBook = nil
        currentChapter = nil
        clock.setCurrentTime(0)
        duration = 0
        WidgetSync.clear()
    }

    func stop() {
        // 收了就报一声：跳过静音到底省了多少时间，日志里得有个总数（验收也看这一行）
        if silenceSkipped > 0 {
            NSLog("[sonux] silenceSkip: 本次播放共跳过 %.0f s 静音", silenceSkipped)
        }
        silenceSkipped = 0
        silenceGaps = [:]
        silenceGapsBookId = nil
        flushListening()
        accountProgress(force: true)
        player?.pause()
        teardownPlayer()
        isPlaying = false
        // 先把「停在这儿」推给小组件，再清空手上的书：否则小组件会凭空断掉这本书，
        // 退化成空状态而不是「上次听到这里」
        if let book = currentBook, let chapter = currentChapter { syncWidget(book: book, chapter: chapter) }
        currentBook = nil
        currentChapter = nil
        clock.setCurrentTime(0)
        duration = 0
        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
        cancelSleepTimer()
        // 这本已经结清了，重新开播要当新的一笔记
        lastAccountedPosition = nil
        // 锁屏与车载上那一行字得跟着撤：不清就留着一张「还在播这本」的假卡片，
        // 人在车里按播放键，手上却没书，什么也不会发生
        updateNowPlaying()
    }

    /// 彻底放手：连播放器实例一起丢，内存与音频链路都还给系统
    /// （下次播放由 ensurePlayer() 重建，代价比留着空播放器占住输出小）
    private func teardownPlayer() {
        unloadItem()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player = nil
    }

    /// 卸掉当前 item 和挂在它身上的监听：换文件、停止都要先清，否则旧 item 的
    /// 播完与失败回调会跑到新一章头上
    private func unloadItem() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        itemEndObserver = nil
        if let itemFailObserver { NotificationCenter.default.removeObserver(itemFailObserver) }
        itemFailObserver = nil
        player?.replaceCurrentItem(with: nil)
        loadedFileURL = nil
        seekIssuedAt = nil
    }

    // MARK: - 跳过静音

    /// 此刻正落在一段该跳的静音里吗？是就把播放位置挪到下一句开口之前，返回跳过的秒数
    ///
    /// 静音地图来自字幕（见 SilenceGaps）：没有字幕的书、还没读到内存的书都不介入，
    /// 宁可什么都不跳，也不凭猜去挪用户的位置。
    private func skipSilenceIfNeeded(chapter: Chapter, local: TimeInterval) -> TimeInterval? {
        guard let minGap = PlaybackSettings.shared.silenceMode.minGap else { return nil }
        if silenceGapsBookId != chapter.bookId {
            silenceGapsBookId = chapter.bookId
            silenceGaps = [:]
        }
        if silenceGaps[chapter.id] == nil {
            let lines = TranscriptStore.shared.lines(forChapter: chapter.id)
            guard !lines.isEmpty else {
                // 字幕还没读进来（从锁屏、小组件直接开播就不会走播放页）：催一次，下一格再判
                if let book = currentBook { Task { await TranscriptStore.shared.load(book: book) } }
                return nil
            }
            silenceGaps[chapter.id] = SilenceGaps.gaps(from: lines, chapterDuration: chapter.duration)
        }
        guard let gaps = silenceGaps[chapter.id],
              let target = SilenceGaps.skipTarget(in: gaps, at: local, minGap: minGap),
              target - local > 0.05 else { return nil }
        let jumped = target - local
        silenceSkipped += jumped
        clock.setCurrentTime(target)
        seekPrecise(toFileTime: chapter.fileTime(target))
        accountProgress()
        NSLog("[sonux] silenceSkip: 《%@》跳过 %.1f s 静音落到 %.0f s（本次累计 %.0f s）",
              chapter.title, jumped, target, silenceSkipped)
        return jumped
    }

    // MARK: - 语音增强

    /// 把处理链挂到这条音轨的混音上。
    ///
    /// 只在「打开」时接链，关掉时不拆：拆 mix 会让音频链路重接一次，正听着就是「卡一下」，
    /// 而 tap 关着的时候一个采样都不动，白占一点 CPU 换来不卡顿。
    private func attachVoiceBoost(to item: AVPlayerItem, for url: URL) {
        guard PlaybackSettings.shared.voiceBoost, item.audioMix == nil, VoiceTap.shared.ref != nil else { return }
        if let trackID = audioTrackIDs[url] {
            item.audioMix = VoiceTap.shared.audioMix(trackID: trackID)
            return
        }
        guard !trackLookupTried.contains(url) else { return }
        trackLookupTried.insert(url)
        // 音轨 id 要问资产要（异步），而 item 已经要开始出声了：到手再补 mix，
        // 最迟只晚几百毫秒，换来切章不用等
        let asset = item.asset
        Task { [weak self] in
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let trackID = tracks.first?.trackID, trackID != 0, let self else {
                NSLog("[sonux] voiceBoost: 拿不到 %@ 的音轨 id，增强不生效", url.lastPathComponent)
                return
            }
            self.audioTrackIDs[url] = trackID
            guard self.player?.currentItem === item, PlaybackSettings.shared.voiceBoost else { return }
            item.audioMix = VoiceTap.shared.audioMix(trackID: trackID)
        }
    }

    /// 设置页上的开关要当下就生效，不能等下一章：增强在这里补链接
    private func observePlaybackSettings() {
        PlaybackSettings.shared.voiceBoostChanges
            .sink { [weak self] on in
                guard on else { return }
                Task { @MainActor in
                    guard let self, let item = self.player?.currentItem, let url = self.loadedFileURL else { return }
                    self.attachVoiceBoost(to: item, for: url)
                }
            }
            .store(in: &cancellables)
    }

    /// 每 10 格报一次处理链的动静：帧数为 0 就说明链没接上，日志里一眼能看出来
    private func reportVoiceBoostHeartbeat() {
        guard PlaybackSettings.shared.voiceBoost else { return }
        let stats = VoiceTap.shared.drainStats()
        NSLog("[sonux] voiceBoost: 近 10 s 过链 %d 次 / %d 帧，峰值 %.3f（%@）",
              stats.calls, stats.frames, stats.peak, stats.format)
    }

    // MARK: - 定时关闭

    func setSleepTimer(_ mode: SleepTimerMode) {
        clearSleepTimer()
        sleepMode = mode
        rememberSleepMode(mode)
        // 用户主动设置即视为新一轮定时，清除待恢复状态
        pendingSleepMode = nil
        pendingSleepRemaining = 0

        switch mode {
        case .off:
            sleepRemaining = 0
        case .chapters:
            // 章数定时没有秒表：播完一章减一格，全在章界停（见 finishCurrentChapter）
            sleepRemaining = 0
        case .minutes(let minutes):
            startSleepCountdown(from: TimeInterval(minutes * 60))
        }
    }

    private func sleepElapsed() {
        toggleOffIfPlaying()
    }

    /// 定时到达或本章播完：暂停播放并清除定时器
    private func toggleOffIfPlaying() {
        player?.pause()
        isPlaying = false
        if case .minutes = sleepMode {
            // 秒表已经走到零，剩下的不是「待走完的剩余」：cancelSleepTimer 只留得下正数，
            // 于是下次出声按记忆的分钟数满额重计
            cancelSleepTimer()
        } else {
            // 章数定时是一次性的：该听的章听完了就是兑现，
            // 不能再留给下次播放，否则它会变成“每 N 章就关一次”永远摘不掉
            clearSleepTimer()
        }
        updateNowPlaying()
    }

    /// 定时整个撤掉时调用（停止播放、定时归零）：把未走完的分钟留给下次出声，届时从剩余接着走
    /// 暂停不在这里走：秒表本来就只在出声时扣（见 tickSleepCountdown），暂停中读数原地等着
    /// 章数定时不保留：它只对应设定时那之后要播完的几章，换个位置再沿用就成了“每 N 章都关”
    private func cancelSleepTimer() {
        guard sleepMode != .off else { return }
        if case .minutes = sleepMode, sleepRemaining > 0 {
            pendingSleepMode = sleepMode
            pendingSleepRemaining = sleepRemaining
        }
        clearSleepTimer()
    }

    /// 只停表并清除状态，不记入待恢复（设置新定时或用户主动取消时用）
    private func clearSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepMode = .off
        sleepRemaining = 0
    }

    /// 从剩余时间继续倒计时，不重置为满额
    private func resumeSleepTimer(mode: SleepTimerMode, remaining: TimeInterval) {
        clearSleepTimer()
        sleepMode = mode
        startSleepCountdown(from: remaining)
    }

    private func startSleepCountdown(from remaining: TimeInterval) {
        sleepRemaining = remaining
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                self.tickSleepCountdown()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    /// 秒表走一格：只在真出声时扣。暂停着还在倒，等于把没在听的那段时间也算进额度，
    /// 人回来接着听没多久就被掐掉——它该数的是「听了多久」，不是「过了多久」
    func tickSleepCountdown() {
        guard isPlaying else { return }
        sleepRemaining -= 1
        if sleepRemaining <= 0 { sleepElapsed() }
    }

    // MARK: - 定时关闭的章数与时间换算

    /// 定时关闭还要多少墙钟秒：分钟定时是秒表读数，章数定时换算成听完这些章要多久。
    /// 面板标题与播放页那枚时钟角标都读它，两处报的是同一个数
    var sleepSecondsLeft: TimeInterval {
        if case .chapters(let count) = sleepMode { return sleepMinutes(forChapters: count) * 60 }
        return sleepRemaining
    }

    /// 听完 count 章大约还要多少墙钟分钟：本章剩下的那点算第一章，本章已经听完就从下一章整章起算，
    /// 再按当前倍速折算成人坐在耳机前的时间
    func sleepMinutes(forChapters count: Int) -> Double {
        guard let seconds = audioSeconds(forChapters: count) else { return 0 }
        return seconds / 60 / Double(max(speed, 0.1))
    }

    /// 从现在起听完 count 章要听多少音频秒；手上没书没章节时给不出数
    private func audioSeconds(forChapters count: Int) -> TimeInterval? {
        guard let book = currentBook, let chapter = currentChapter,
              let idx = book.chapters.firstIndex(where: { $0.id == chapter.id }) else { return nil }
        let remaining = max(chapter.duration - currentTime, 0)
        var legs: [TimeInterval] = remaining < 1 ? [] : [remaining]
        var at = idx + 1
        while legs.count < count, book.chapters.indices.contains(at) {
            legs.append(book.chapters[at].duration)
            at += 1
        }
        return legs.reduce(0, +)
    }

    // MARK: - Private

    private func speedValue() -> Float {
        speed
    }

    private func chapter(in book: Book, for position: PlayPosition?) -> Chapter? {
        guard let position else { return book.chapters.first }
        return book.chapters.first { $0.id == position.chapterId }
    }

    private func positionTime(in book: Book, chapter: Chapter, position: PlayPosition?) -> TimeInterval {
        guard let position, position.chapterId == chapter.id else { return 0 }
        return ProgressPolicy.resumeTime(time: position.time, duration: chapter.duration)
    }

    /// 章节的历史播放位置（已播完或未记录则从头播放）：切章时人还在连续听，不做续播回退
    private func resumeTime(for chapter: Chapter) -> TimeInterval {
        chapterHistory?(chapter.id).map {
            ProgressPolicy.resumeTime(time: $0.time, duration: chapter.duration, rewind: false)
        } ?? 0
    }

    // MARK: - 播放器时间换算与精确跳转

    private static func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// 播放器此刻在文件时间轴上的秒。未就绪时 currentTime 是 .invalid（秒为 NaN），按 0 处理
    private var fileTimeNow: TimeInterval {
        guard let player else { return 0 }
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// 样本精确地跳到文件内某秒：两端容差都取 0。章界与逐句开播差半秒就够把上一章的尾巴
    /// 算进下一章，而音频不像视频要等关键帧，代价只是多一点解码准备
    private func seekPrecise(toFileTime seconds: TimeInterval) {
        guard let player, player.currentItem != nil else { return }
        seekIssuedAt = Date()
        seekGeneration += 1
        let generation = seekGeneration
        player.seek(to: Self.cmTime(seconds), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                // 期间又切了章或再拖了一次位置：这一次的结果已经不作数
                guard let self, self.seekGeneration == generation else { return }
                self.seekIssuedAt = nil
            }
        }
    }

    /// 是否还有一次 seek 没落地（超时视为已落地，见 seekSettleTimeout）
    private var seekPending: Bool {
        guard let issuedAt = seekIssuedAt else { return false }
        guard Date().timeIntervalSince(issuedAt) < Self.seekSettleTimeout else {
            seekIssuedAt = nil
            return false
        }
        return true
    }

    /// 已经播到当前 item 的结尾：这时候再给 rate 也只会立刻停在这儿，
    /// 必须重装 item（或跳到中间）才会真的出声
    private var isAtItemEnd: Bool {
        guard let item = player?.currentItem else { return false }
        let end = CMTimeGetSeconds(item.duration)
        let now = fileTimeNow
        guard end.isFinite, end > 0 else { return false }
        return now >= end - 0.5
    }

    func currentPosition() -> PlayPosition? {
        guard let chapter = currentChapter else { return nil }
        return PlayPosition(chapterId: chapter.id, time: currentTime)
    }

    /// 向书库结一次账：位置 + 攒下的收听秒数，书库端连着落盘。
    /// 播放中每 `progressAccountingInterval` 秒一次；暂停、停止、切章、拖进度当场补一次。
    /// 账没动（位置与上次记的一样、这一趟也没攒到新收听秒数）就直接返回，不碰磁盘
    private func accountProgress(force: Bool = false) {
        guard let book = currentBook else { return }
        let now = Date()
        let position = currentPosition()
        let moved = position != nil && position != lastAccountedPosition
        guard Self.shouldAccountProgress(now: now, last: lastAccountedAt,
                                         pendingSeconds: pendingListeningSeconds,
                                         positionChanged: moved, force: force) else { return }
        lastAccountedAt = now
        if pendingListeningSeconds > 0 {
            onListening?(pendingListeningSeconds, book.id)
            pendingListeningSeconds = 0
        }
        guard let position else { return }
        lastAccountedPosition = position
        onPositionChange?(position)
    }

    /// 这一趟该不该结账：纯判据，抽出来好把「30 秒窗口 + 当场结清 + 没账可结」三种情况钉死
    nonisolated static func shouldAccountProgress(now: Date, last: Date?, pendingSeconds: TimeInterval,
                                                  positionChanged: Bool, force: Bool,
                                                  interval: TimeInterval = progressAccountingInterval) -> Bool {
        // 没东西可记就别写盘：暂停期间进度计时器还在每秒走这一趟
        guard pendingSeconds > 0 || positionChanged else { return false }
        if force { return true }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    private func startProgressTimer() {
        displayLinkTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.hasPlayer else { return }
                if self.isPlaying {
                    let t0 = CACurrentMediaTime()
                    self.touchResumeClock()
                    self.accumulateListening()
                    let chapter = self.currentChapter
                    let fileTime = self.fileTimeNow
                    if self.seekPending {
                        // seek 还没落地：播放器报的可能是上一段的秒，拿它判章尾会凭空跳一章
                    } else if let chapter, self.nextChapterInSameFile() != nil,
                              fileTime >= chapter.fileEnd - Self.chapterEndTolerance {
                        // 内嵌章节的书：一章只是文件里的一段，到点得在这儿自己判（文件没播完不会来 didPlayToEnd）
                        self.finishCurrentChapter()
                    } else {
                        let local = chapter.map { $0.localTime(fileTime) } ?? fileTime
                        self.clock.setCurrentTime(local)
                        // 跳过静音：落在字幕空档里就把位置挪到下一句开口前，跳过了就不再重复报进度
                        var jumped: TimeInterval?
                        if let chapter { jumped = self.skipSilenceIfNeeded(chapter: chapter, local: local) }
                        if jumped == nil { self.accountProgress() }
                    }
                    self.progressTicks += 1
                    if self.progressTicks % 10 == 0 { self.reportVoiceBoostHeartbeat() }
                    let ms = (CACurrentMediaTime() - t0) * 1000
                    if ms > 50 { NSLog("[sonux] progressTick: 耗时 %.1f ms", ms) }
                } else {
                    // 暂停中：把最后一段收听时长收尾，恢复播放后重新起算。
                    // 顺手结一次账：账没动时 accountProgress 自己会跳过，不会每秒写盘
                    self.flushListening()
                    self.accountProgress(force: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayLinkTimer = timer
    }

    /// 同一文件里的下一章（只有内嵌章节的书才有）：取不到说明本章已经到这个文件的结尾，
    /// 那一声 didPlayToEnd 会来收尾，不必在计时里再判一次
    private func nextChapterInSameFile() -> Chapter? {
        guard let book = currentBook, let chapter = currentChapter,
              let idx = book.chapters.firstIndex(where: { $0.id == chapter.id }),
              book.chapters.indices.contains(idx + 1) else { return nil }
        let next = book.chapters[idx + 1]
        return next.fileURL == chapter.fileURL ? next : nil
    }

    /// 退到后台那一刻把账结清：位置与攒下的收听秒数当场落盘，不等 30 秒的节流窗口。
    /// 只挂着书没出声（没装载播放器）时不结，否则会拿启动挂上的位置顶掉真正的最后收听时间
    func settleProgressForBackground() {
        guard hasPlayer else { return }
        flushListening()
        accountProgress(force: true)
    }

    /// 一章播完：把位置记到章尾、通知外部，再按定时关闭停下或续播下一章
    private func finishCurrentChapter() {
        guard let chapter = currentChapter, let book = currentBook else { return }
        NSLog("[sonux] finishChapter: 《%@》播完（记到 %.0f s）", chapter.title, chapter.duration)
        clock.setCurrentTime(chapter.duration)
        accountProgress(force: true)
        onChapterFinished?(chapter, book)

        if case .chapters(let remaining) = sleepMode {
            guard remaining > 1 else {
                // 最后一章也听完了：定时兑现，就停在这一章的结尾，
                // 别先进下一章，免得人醒来发现已经溜过去一章的开头
                toggleOffIfPlaying()
                return
            }
            // 只改剩余章数，不走 setSleepTimer：那是「用户设的章数」的记忆，
            // 让倒数去写它，一夜之后默认值就被改成了 1 章
            sleepMode = .chapters(remaining - 1)
            NSLog("[sonux] sleepTimer: 播完一章，还剩 %d 章后关闭", remaining - 1)
        }
        advanceToNextChapter()
    }

    /// 自动续播下一章：同一文件里的章节原地跳偏移，换了文件才重装 item
    private func advanceToNextChapter() {
        guard let book = currentBook, let chapter = currentChapter,
              let idx = book.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
        let next = idx + 1
        guard book.chapters.indices.contains(next) else {
            NSLog("[sonux] advance: 《%@》已播到最后一章", book.title)
            // 整本书听到头了，章数定时还挂着几章也等不到，别留一个永远走不完的读数
            if case .chapters = sleepMode { clearSleepTimer() }
            isPlaying = false
            updateNowPlaying()
            return
        }
        let target = book.chapters[next]
        if target.fileURL == chapter.fileURL {
            NSLog("[sonux] advance: 同一个文件内跳到《%@》（文件 %.0f s 处）", target.title, target.fileStart)
        }
        play(chapter: target, book: book, fromTime: resumeTime(for: target))
    }

    // MARK: - 收听时长统计

    /// 把上次计时点到现在的一段真实收听秒数攒起来：等下一次结账一起报给统计
    private func accumulateListening() {
        let now = Date()
        defer { listeningAnchor = now }
        guard let anchor = listeningAnchor, currentBook != nil else { return }
        let delta = now.timeIntervalSince(anchor)
        // 定时器抖动、后台挂起造成的长空档不计入收听时长
        guard delta > 0, delta < 10 else { return }
        pendingListeningSeconds += delta
    }

    /// 结束本次计时（暂停、停止、切书前都要调一次）
    private func flushListening() {
        guard listeningAnchor != nil else { return }
        accumulateListening()
        listeningAnchor = nil
    }

    /// 激活音频会话：只在真正要出声的那一刻调用。
    /// 早到 App 启动就激活，会抢走音频焦点，把用户正在别的 App 里听的音乐暂停掉。
    /// setCategory / setActive 是同步阻塞调用（Apple 把它列为 runtime issue
    /// “AVAudioSession Hang Risk”），模拟器里首次激活还要跑 CoreAudio 插件枚举，实测占主线程上百毫秒；
    /// 会话没被系统收走就别重复跑，否则每次点播放都要卡一下
    private func activateAudioSession() {
        guard !audioSessionActivated else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            audioSessionActivated = true
        } catch {
            NSLog("[sonux] play: 激活音频会话失败 %@", error.localizedDescription)
        }
    }

    /// 已发起封面提取的书 id，避免同一本书重复调度
    private var artworkLoadingBookId: String?

    private func updateNowPlaying() {
        let t0 = CACurrentMediaTime()
        guard let chapter = currentChapter, let book = currentBook else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speedValue(),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speedValue() : 0.0,
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            // 第几章 / 一共几章：锁屏不显示，但 CarPlay 的现在播放与方向盘那两枚
            // 上一曲/下一曲靠这两个数知道自己在整本书的哪儿，播报进度时也用它
            MPNowPlayingInfoPropertyChapterNumber: chapter.index + 1,
            MPNowPlayingInfoPropertyChapterCount: book.chapters.count,
        ]
        if let author = book.author {
            info[MPMediaItemPropertyArtist] = author
        }
        // 锁屏封面：内嵌大图还没取到时先用现有封面或占位封面，取完再刷新一次
        let cover = CoverStore.shared.lockScreenCover(for: book)
        let coverSource = CoverStore.shared.hasEmbeddedCover(for: book) ? "内嵌" : "占位"
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        scheduleCoverLoad(for: book)
        NSLog("[sonux] updateNowPlaying: 锁屏封面 %@ %.0fx%.0f", coverSource, cover.size.width, cover.size.height)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        syncWidget(book: book, chapter: chapter)
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 30 { NSLog("[sonux] updateNowPlaying: 耗时 %.1f ms", ms) }
    }

    /// 把当前收听状态推给桌面小组件。与锁屏信息同一时机上报（播、停、切章、变速、拖过进度）
    private func syncWidget(book: Book, chapter: Chapter) {
        WidgetSync.publish(book: book, chapter: chapter, isPlaying: isPlaying)
    }

    /// 封面刚提取到手时重发一次快照：小组件据此决定铺真封面还是把书名占位图糊成底色
    /// （冷启动挂着没播的那本不走 updateNowPlaying，没这一句就会一直拿着启动时那张占位图）
    func refreshWidgetSnapshot() {
        guard let book = currentBook, let chapter = currentChapter else { return }
        syncWidget(book: book, chapter: chapter)
    }

    /// 后台提取当前书的大图封面，完成后回写锁屏展示；同一本书只调度一次
    private func scheduleCoverLoad(for book: Book) {
        guard !CoverStore.shared.largeCoverResolved(for: book), artworkLoadingBookId != book.id else { return }
        artworkLoadingBookId = book.id
        Task { [weak self] in
            await CoverStore.shared.loadLarge(for: book)
            guard let self else { return }
            self.artworkLoadingBookId = nil
            guard self.currentBook?.id == book.id else { return }
            self.updateNowPlaying()
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumePlayback() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pausePlayback() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextChapter() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousChapter() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.setSpeed(event.playbackRate) }
            return .success
        }
        // 前后跳过区间都用 15 秒，与播放页进度条两侧的快进/快退按钮一致
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.skip(by: TimeInterval(interval)) }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            Task { @MainActor in self?.skip(by: -TimeInterval(interval)) }
            return .success
        }
    }

    /// 锁屏“播放”：暂停中的音频直接续播，没装载或已播到结尾就重新开播当前书
    @MainActor func resumePlayback() {
        if let player, player.currentItem != nil, player.timeControlStatus == .paused, !isAtItemEnd {
            activateAudioSession()
            rewindAfterPauseIfNeeded()
            player.rate = speedValue() // 不能用 play()：它会把倍速抹回 1.0
            isPlaying = true
            touchResumeClock()
            startProgressTimer()
            applyRememberedSleepTimerIfNeeded()
            updateNowPlaying()
        } else if let player, player.rate != 0 {
            // 还在播或在缓冲：再点一次播放不该把人当前位置打回重来
            isPlaying = true
            updateNowPlaying()
        } else if let book = currentBook {
            play(book: book, at: currentPosition())
        }
    }

    @MainActor func pausePlayback() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }
}

// MARK: - 播放状态与 item 事件

extension PlayerService {
    /// 盯住当前 item：解码失败要能说清「为什么没出声」，文件播到结尾要续下一章。
    /// 内嵌章节的书只在文件最后一章收到这一声，章间边界由进度计时自己判
    private func watch(_ item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in self?.reportItemStatus(item) }
        }
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.itemDidPlayToEnd(item) }
        }
        if let itemFailObserver { NotificationCenter.default.removeObserver(itemFailObserver) }
        itemFailObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.reportPlaybackFailure(error)
            }
        }
    }

    /// 监听播放器的起停状态：AVPlayer 会自己停（播完、出错、会话被系统收回），
    /// 界面、锁屏与收听时长统计都得跟着它，不能只跟着按钮
    private func observeTimeControl(of player: AVPlayer) {
        timeControlObservation?.invalidate()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.timeControlChanged(player.timeControlStatus) }
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            guard !isPlaying else { return }
            isPlaying = true
            listeningAnchor = Date()
            startProgressTimer()
        case .paused:
            guard isPlaying else { return }
            flushListening()
            isPlaying = false
            updateNowPlaying()
        case .waitingToPlayAtSpecifiedRate:
            // 缓冲中不算停：用户仍是「在听」，播放键这时闪成暂停反而更乱
            break
        @unknown default:
            break
        }
    }

    private func reportItemStatus(_ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .readyToPlay, .unknown:
            break
        case .failed:
            reportPlaybackFailure(item.error)
        @unknown default:
            break
        }
    }

    /// 出声失败不能静默停在「看似还在播」的状态：界面要停下，锁屏要清掉速率
    private func reportPlaybackFailure(_ error: Error?) {
        let reason = error?.localizedDescription ?? "未知错误"
        NSLog("[sonux] play: 播放《%@》失败 %@", currentChapter?.title ?? "?", reason)
        flushListening()
        isPlaying = false
        updateNowPlaying()
    }

    private func itemDidPlayToEnd(_ item: AVPlayerItem) {
        guard item === player?.currentItem, currentChapter != nil else { return }
        // 这一声只在真播到文件结尾时来。AVAudioPlayer 的 finish flag 在倍速、路由切换时
        // 会误报 false，得靠位置兜底；AVPlayer 不需要，所以也不用再判一次位置
        finishCurrentChapter()
    }
}

// MARK: - Interrupt / Route handling

extension PlayerService {
    /// 监听系统音频中断（电话、Siri 等）
    func observeInterruptions() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .compactMap { notification in
                notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? AVAudioSession.InterruptionType
            }
            .sink { [weak self] type in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch type {
                    case .began:
                        // 系统把会话收走了，下次播放要重新激活
                        self.audioSessionActivated = false
                        self.wasPlayingBeforeInterruption = self.isPlaying
                        self.player?.pause()
                        self.isPlaying = false
                        self.updateNowPlaying()
                    case .ended:
                        // 中断期间声音已经重新出来了（语音意图刚开播、锁屏上按了播放），
                        // 就别再拿「中断前没在播」去把它掐掉——那句「嘿 Siri，播放我的书」
                        // 正是这样被自己刚起的播覆盖掉的
                        if self.isPlaying {
                            NSLog("[sonux] interrupt: 中断结束时已在播放，保持不动")
                        } else {
                            self.handleInterruption(shouldResume: self.wasPlayingBeforeInterruption)
                        }
                        self.wasPlayingBeforeInterruption = false
                    @unknown default:
                        break
                    }
                }
            }
            .store(in: &cancellables)
    }

    func handleInterruption(shouldResume: Bool) {
        guard let player = player, player.currentItem != nil else { return }
        if shouldResume {
            activateAudioSession()
            rewindAfterPauseIfNeeded()
            player.rate = speedValue()
            isPlaying = true
            touchResumeClock()
        } else {
            // 不打算续播就别重新占住会话，否则会把中断期间接着放音乐的用户再挤走
            player.pause()
            isPlaying = false
        }
        updateNowPlaying()
    }

    /// 监听输出设备变化：拔有线耳机、蓝牙断连、耳机摘下回盒，都走这一条
    func observeRouteChanges() {
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .compactMap { Self.routeChangeReason(from: $0) }
            .sink { [weak self] reason in
                Task { @MainActor in self?.handleRouteChange(reason: reason) }
            }
            .store(in: &cancellables)
    }

    /// 取通知里那条 reason：系统给的是 NSNumber，缺键或不是数字就当与路由无关，不处理
    nonisolated static func routeChangeReason(from notification: Notification) -> AVAudioSession.RouteChangeReason? {
        guard let number = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber else { return nil }
        return AVAudioSession.RouteChangeReason(rawValue: number.uintValue)
    }

    /// 声音原先走的那台设备没了就停下：不停的话系统把同一股流甩给本机喇叭，
    /// 人已经不在耳机前，越放越响只会吵到旁人
    ///
    /// 顺手抹掉「中断前在播」的标记：设备断连常和系统中断前后脚发生，留着它，
    /// 中断一结束就会把已经没人听的那一本从喇叭里放回声音来
    func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        guard Self.shouldPauseOnRouteChange(reason) else { return }
        wasPlayingBeforeInterruption = false
        guard isPlaying else { return }
        NSLog("[sonux] route: 输出设备已断开（reason=%@），暂停播放", NSNumber(value: reason.rawValue))
        pausePlayback()
    }

    /// 只有「旧设备消失」才停播（拔线、断连、耳机回盒），其余 reason 都可能出现在正常听音途中，
    /// 多停一次就是一次「怎么突然没声了」：
    /// - newDeviceAvailable：接上耳机或音箱，不该把正在放的掐掉
    /// - categoryChange：别的 App 改会话、或我们自己 setCategory 时系统补发的
    /// - override / routeConfigurationChange：输出被切到听筒或某端口的数据源变了，设备没少
    /// - wakeFromSleep / noSuitableRouteForCategory / unknown：唤醒与路由探测，与「人走了」无关
    nonisolated static func shouldPauseOnRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        reason == .oldDeviceUnavailable
    }
}
