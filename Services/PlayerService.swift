import Foundation
import AVFoundation
import MediaPlayer
import QuartzCore
import Combine

/// 定时关闭模式：分钟数可在滑动条范围内任意设置，也可在本章播完时关闭
enum SleepTimerMode: Equatable {
    case off
    case minutes(Int)
    case endOfChapter

    /// 滑动条可设置的分钟范围与步进：0–90，每格 1 分钟
    static let range: ClosedRange<Double> = 0...90
    static let step: Double = 1
}

/// 播放服务：基于 AVAudioPlayer，负责播放、进度回调、锁屏控制与定时关闭
@MainActor
final class PlayerService: NSObject, ObservableObject {
    // 当前播放状态
    @Published private(set) var currentBook: Book?
    @Published private(set) var currentChapter: Chapter?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var speed: Float = 1.0
    /// 是否展示全屏播放界面（点列表播放时直接打开）
    @Published var showPlayer = false
    // 定时关闭
    @Published private(set) var sleepMode: SleepTimerMode = .off
    @Published private(set) var sleepRemaining: TimeInterval = 0

    var onChapterFinished: ((Chapter, Book) -> Void)?
    /// 周期性进度上报（播完一章时也会调用一次结尾位置）
    var onPositionChange: ((PlayPosition) -> Void)?
    /// 查询某章节的历史播放位置（自动续播到下一章时使用）
    var chapterHistory: ((String) -> PlayPosition?)?

    private var player: AVAudioPlayer?
    private var displayLinkTimer: Timer?
    private var sleepTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// 被打断前是否处于播放状态（用于中断结束后自动恢复）
    private var wasPlayingBeforeInterruption = false
    /// 连续语速范围与步进：0.5x–3x，每格 0.1
    static let speedRange: ClosedRange<Double> = 0.5...3.0
    static let speedStep: Double = 0.1

    // MARK: - 定时关闭记忆（参考微信读书：下次播放自动沿用上次设置）

    private static let lastSleepModeKey = "sleepTimer.lastMode"
    private static let lastSleepMinutesKey = "sleepTimer.lastMinutes"

    /// 上次用户设置的定时关闭模式（定时自然到期不清除，供下次播放沿用）
    private var rememberedSleepMode: SleepTimerMode? {
        switch UserDefaults.standard.integer(forKey: Self.lastSleepModeKey) {
        case 1:
            let minutes = UserDefaults.standard.integer(forKey: Self.lastSleepMinutesKey)
            return minutes > 0 ? .minutes(minutes) : nil
        case 2:
            return .endOfChapter
        default:
            return nil
        }
    }

    /// 仅记录用户主动选择的模式（定时自然到期不清除记忆）
    private func rememberSleepMode(_ mode: SleepTimerMode) {
        switch mode {
        case .off:
            UserDefaults.standard.set(0, forKey: Self.lastSleepModeKey)
        case .minutes(let minutes):
            UserDefaults.standard.set(1, forKey: Self.lastSleepModeKey)
            UserDefaults.standard.set(minutes, forKey: Self.lastSleepMinutesKey)
        case .endOfChapter:
            UserDefaults.standard.set(2, forKey: Self.lastSleepModeKey)
        }
    }

    /// 播放被中断时未走完的定时（暂停/停止时保留剩余时间，恢复播放时接着走）
    private var pendingSleepMode: SleepTimerMode?
    private var pendingSleepRemaining: TimeInterval = 0
    /// 上次定时是否已自然走完：只有此时，重新播放才用记忆的默认时长重新计时；
    /// 否则只恢复剩余时间，避免暂停再播放就满额重计、永无止境
    private var sleepTimerDidExpire = false

    override init() {
        super.init()
        configureAudioSession()
        setupRemoteCommands()
        observeInterruptions()
    }

    // MARK: - 播放控制

    /// 从指定位置开始播放一本书
    func play(book: Book, at position: PlayPosition?) {
        guard let chapter = chapter(in: book, for: position) ?? book.chapters.first else { return }
        let time = positionTime(in: book, chapter: chapter, position: position)
        play(chapter: chapter, book: book, fromTime: time)
    }

    /// 播放某一章节
    func play(chapter: Chapter, book: Book, fromTime: TimeInterval = 0) {
        do {
            let player = try AVAudioPlayer(contentsOf: chapter.fileURL)
            player.prepareToPlay()
            player.enableRate = true
            player.rate = speedValue()
            player.delegate = self
            player.currentTime = min(max(0, fromTime), max(chapter.duration - 0.5, 0))

            self.player?.stop()
            self.player = player
            self.currentBook = book
            self.currentChapter = chapter
            self.duration = chapter.duration
            self.currentTime = player.currentTime
            self.isPlaying = true
            player.play()

            startProgressTimer()
            applyRememberedSleepTimerIfNeeded()
            updateNowPlaying()
        } catch {
            self.isPlaying = false
        }
    }

    /// 恢复播放时接续之前的定时：
    /// - 定时未走完（如暂停后继续）→ 从剩余时间接着走，不重新满额计时
    /// - 定时已完全走完后再重新播放（如半夜醒来）→ 沿用记忆的默认时长重新计时
    private func applyRememberedSleepTimerIfNeeded() {
        guard sleepMode == .off, player?.isPlaying == true else { return }
        if let mode = pendingSleepMode {
            pendingSleepMode = nil
            if mode == .endOfChapter {
                setSleepTimer(.endOfChapter)
            } else if pendingSleepRemaining > 0 {
                resumeSleepTimer(mode: mode, remaining: pendingSleepRemaining)
            }
            pendingSleepRemaining = 0
        } else if sleepTimerDidExpire, let mode = rememberedSleepMode {
            setSleepTimer(mode)
        }
    }

    func togglePlayPause() {
        let t0 = CACurrentMediaTime()
        NSLog("[sonux] togglePlayPause: begin isPlaying=%d", isPlaying ? 1 : 0)
        guard let player = player else {
            NSLog("[sonux] togglePlayPause: no player, replay book")
            if let book = currentBook { play(book: book, at: currentPosition()) }
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            NSLog("[sonux] togglePlayPause: paused %.1f ms", (CACurrentMediaTime() - t0) * 1000)
        } else {
            player.play()
            player.rate = speed // 暂停期间调整的倍速需重新应用
            isPlaying = true
            applyRememberedSleepTimerIfNeeded()
            NSLog("[sonux] togglePlayPause: resumed %.1f ms", (CACurrentMediaTime() - t0) * 1000)
        }
        updateNowPlaying()
        NSLog("[sonux] togglePlayPause: done total %.1f ms", (CACurrentMediaTime() - t0) * 1000)
    }

    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
        reportPosition()
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
        // 限制在语速范围内并对齐到 0.1 步进，避免浮点误差累积
        let clamped = min(max(value, Float(Self.speedRange.lowerBound)), Float(Self.speedRange.upperBound))
        let rounded = (clamped * 10).rounded() / 10
        speed = rounded
        player?.rate = rounded
        if let player, player.isPlaying {
            player.rate = rounded // 确保生效
        }
        updateNowPlaying()
    }

    func stop() {
        reportPosition()
        player?.stop()
        player = nil
        currentBook = nil
        currentChapter = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
        cancelSleepTimer()
    }

    // MARK: - 定时关闭

    func setSleepTimer(_ mode: SleepTimerMode) {
        clearSleepTimer()
        sleepMode = mode
        rememberSleepMode(mode)
        // 用户主动设置即视为新一轮定时，清除待恢复状态
        pendingSleepMode = nil
        pendingSleepRemaining = 0
        sleepTimerDidExpire = false

        switch mode {
        case .off:
            sleepRemaining = 0
        case .endOfChapter:
            // 由 didFinishPlaying 处理：本章结束后停止
            sleepRemaining = max(duration - currentTime, 0)
        case .minutes(let minutes):
            let seconds = TimeInterval(minutes * 60)
            sleepRemaining = seconds
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self = self else { timer.invalidate(); return }
                    self.sleepRemaining -= 1
                    if self.sleepRemaining <= 0 {
                        self.sleepElapsed()
                        timer.invalidate()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            sleepTimer = timer
        }
    }

    private func sleepElapsed() {
        toggleOffIfPlaying()
    }

    /// 定时到达：暂停播放并清除定时器
    private func toggleOffIfPlaying() {
        player?.pause()
        isPlaying = false
        if case .minutes = sleepMode {
            // 倒计时真正走完：下次播放时记忆的默认时长才会生效
            sleepTimerDidExpire = true
        }
        cancelSleepTimer()
        updateNowPlaying()
    }

    /// 暂停/停止时调用：保留未走完的定时，恢复播放时从剩余时间接着走
    private func cancelSleepTimer() {
        guard sleepMode != .off else { return }
        if case .minutes = sleepMode, sleepRemaining > 0 {
            pendingSleepMode = sleepMode
            pendingSleepRemaining = sleepRemaining
        } else if sleepMode == .endOfChapter {
            pendingSleepMode = sleepMode
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
        sleepRemaining = remaining
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                self.sleepRemaining -= 1
                if self.sleepRemaining <= 0 {
                    self.sleepElapsed()
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
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

    /// 章节的历史播放位置（已播完或未记录则从头播放）
    private func resumeTime(for chapter: Chapter) -> TimeInterval {
        chapterHistory?(chapter.id).map {
            ProgressPolicy.resumeTime(time: $0.time, duration: chapter.duration)
        } ?? 0
    }

    func currentPosition() -> PlayPosition? {
        guard let chapter = currentChapter else { return nil }
        return PlayPosition(chapterId: chapter.id, time: currentTime)
    }

    private func reportPosition() {
        guard let chapter = currentChapter, let book = currentBook else { return }
        let position = PlayPosition(chapterId: chapter.id, time: currentTime)
        onPositionChange?(position)
        // 章节末尾 3 秒内不再重复上报
        _ = book
    }

    private func startProgressTimer() {
        displayLinkTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard let player = self.player else { return }
                if player.isPlaying {
                    let t0 = CACurrentMediaTime()
                    self.currentTime = player.currentTime
                    self.reportPosition()
                    let ms = (CACurrentMediaTime() - t0) * 1000
                    if ms > 50 { NSLog("[sonux] progressTick: 耗时 %.1f ms", ms) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayLinkTimer = timer
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

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
        ]
        if let author = book.author {
            info[MPMediaItemPropertyArtist] = author
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 30 { NSLog("[sonux] updateNowPlaying: 耗时 %.1f ms", ms) }
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
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
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

    /// 锁屏“播放”：若已有暂停的播放器则继续，否则从头播放当前书
    @MainActor func resumePlayback() {
        if let player = player, !player.isPlaying {
            player.play()
            isPlaying = true
            startProgressTimer()
            applyRememberedSleepTimerIfNeeded()
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

// MARK: - AVAudioPlayerDelegate

extension PlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard flag, let chapter = self.currentChapter, let book = self.currentBook else { return }
            // 记录本章完成位置
            self.currentTime = chapter.duration
            self.reportPosition()
            self.onChapterFinished?(chapter, book)

            if self.sleepMode == .endOfChapter {
                self.toggleOffIfPlaying()
                return
            }
            self.advanceToNextChapterIfNeeded()
        }
    }

    @MainActor private func advanceToNextChapterIfNeeded() {
        guard let book = currentBook, let chapter = currentChapter,
              let idx = book.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
        let next = idx + 1
        if book.chapters.indices.contains(next) {
            let chapter = book.chapters[next]
            play(chapter: chapter, book: book, fromTime: resumeTime(for: chapter))
        } else {
            isPlaying = false
            updateNowPlaying()
        }
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
                        self.wasPlayingBeforeInterruption = self.isPlaying
                        self.player?.pause()
                        self.isPlaying = false
                        self.updateNowPlaying()
                    case .ended:
                        self.handleInterruption(shouldResume: self.wasPlayingBeforeInterruption)
                        self.wasPlayingBeforeInterruption = false
                    @unknown default:
                        break
                    }
                }
            }
            .store(in: &cancellables)
    }

    func handleInterruption(shouldResume: Bool) {
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = player else { return }
        if shouldResume {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        updateNowPlaying()
    }
}
