import AppIntents

/// 快捷指令库里预置的三条说法，也是 Siri 听得懂的那几句。
/// `\(.applicationName)` 会被换成 App 名，各语言的说法要在 String Catalog 里逐条翻，
/// 翻不动的语言就退回英文——中文用户对着 Siri 说「播放我的书」能不能应，看的就是这张表里的 zh 译文
struct SonuxAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play my book in \(.applicationName)",
                "Continue listening in \(.applicationName)",
            ],
            shortTitle: "Play My Book",
            systemImageName: "book.pages"
        )
        AppShortcut(
            intent: NextChapterIntent(),
            phrases: ["Next chapter in \(.applicationName)"],
            shortTitle: "Next Chapter",
            systemImageName: "forward.end.fill"
        )
        AppShortcut(
            intent: PreviousChapterIntent(),
            phrases: ["Previous chapter in \(.applicationName)"],
            shortTitle: "Previous Chapter",
            systemImageName: "backward.end.fill"
        )
    }
}
