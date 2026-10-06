import AppIntents

// 语音开播与切章的三条意图。共同的两个选择：
// ① `openAppWhenRun = false`——开车的人要的是声音，不是把手机屏幕点亮成播放页，
//    播放器与锁屏/车载的现在播放照样把状态带出去；
// ② `authenticationPolicy = .alwaysAllowed`——手机锁着躺在口袋里也能开播，
//    默认策略要求先解锁，那样在车里说句话只会被系统回一句「请先解锁」。

/// 「播放我的书」：没报书名就接着上次听的那本，报了书名就播那本
struct PlayBookIntent: AppIntent {
    static var title: LocalizedStringResource = "Play a Book"
    static var description = IntentDescription("Play a book from your Sonux library.")
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Book")
    var book: BookEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$book)")
    }

    func perform() async throws -> some IntentResult {
        try await SonuxRuntime.shared.playForVoice(bookId: book?.id)
        return .result()
    }
}

/// 「下一章」：与方向盘那枚下一曲、锁屏那枚 ⏭ 走的是同一条路
struct NextChapterIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Chapter"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    func perform() async throws -> some IntentResult {
        try await SonuxRuntime.shared.advanceChapterForVoice(by: 1)
        return .result()
    }
}

/// 「上一章」：正在播的这一章还没过三秒就真的退一章，否则回到本章开头
struct PreviousChapterIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Chapter"
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    func perform() async throws -> some IntentResult {
        try await SonuxRuntime.shared.advanceChapterForVoice(by: -1)
        return .result()
    }
}
