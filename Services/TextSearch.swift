import Foundation

/// 全文搜索的一条命中：某本书某章里的某一句
///
/// start 是「本章内」的秒，与播放器、字幕行的口径一致，所以点它可以直接从这句开播。
struct TextMatch: Identifiable, Hashable {
    /// 句子按关键词切成的片段，marked 的那几段要在界面上高亮。
    /// 在搜索侧就切好，是因为界面只要「这段文字要不要特殊着色」这一点信息，
    /// 把 String.Index 区间带过去还得再换算一次才能喂给 Text
    struct Segment: Hashable {
        let text: String
        let marked: Bool
    }

    let bookID: String
    let chapterID: String
    let chapterTitle: String
    let start: TimeInterval
    let segments: [Segment]

    var id: String { "\(chapterID)@\(start)" }

    /// 整句原文（去掉分段信息），给无障碍朗读与调试日志用
    var sentence: String { segments.map(\.text).joined() }
}

/// 一本书的命中集合：结果按书分组，书名当小标题，一屏就能扫完「哪些书在讲这个」
struct TextBookHits: Identifiable, Hashable {
    let bookID: String
    /// 列出来的命中句（按书内阅读顺序）
    let matches: [TextMatch]
    /// 超出上限没有列出的句数：常见词动辄几千句，全塞进列表既读不完也拖慢渲染
    let hidden: Int

    var id: String { bookID }
    /// 扫到的命中总数（含没列出的），分组标题显示它，排序也按它
    var totalHits: Int { matches.count + hidden }
}

/// 全库字幕的文本搜索：把 Documents/transcripts/ 里每本书的字幕读一遍，逐句比对关键词
///
/// 这件事只有本 App 做得成：有声书原本只有音频，微信听书与 Audible 都没有逐句时间轴，
/// 而这里 34 本书、25 万句已经全部转写并对好了时间，所以「我记得有段讲 XYZ」能定位到
/// 某一章的某一秒，点一下就从那句开播。
///
/// 为什么不建倒排索引：全库字幕包 17.6 MB、25 万句，实测一趟「读盘 + 解码 + 逐句比对」
/// 只要 300 ms（其中解码 91 ms、比对 200 ms），界面上还能逐本渐进上屏，第一本几十毫秒就出；
/// 多存一份索引就多一份要对齐的脏数据（字幕会被去广告流水线重生成），不划算。
enum LibraryTextSearch {
    /// 每本书最多列出多少句（总数照样统计，只是不再往下存）
    static let perBookLimit = 80

    /// 折叠比对选项：不区分大小写、不分声调、全半角等同（「２００８」也当「2008」搜得到）
    /// 贵，只在原样比对没中且确实可能有写法差异时才用，见 ranges(of:in:)
    private static let foldOptions: String.CompareOptions =
        [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// 扫一本书：返回 nil 表示这本书没有字幕包（区别于「有字幕但一句没命中」）
    ///
    /// 单本书几百 KB，一次扫描几十毫秒，正好当界面上渐进搜索的最小单位。
    /// 这里不借道 TranscriptStore.lines(for:of:in:)：那条路径要为播放做去空、trim 与排序，
    /// 25 万句就是 25 万次字符串分配（实测多花 700 ms）；搜索只要「这一句属不属于本章」
    /// 和「有没有关键词」，所以直接读原始行，命中了才整理成要展示的文字。
    static func scan(book: Book, query: String, transcriptsDir: URL) -> TextBookHits? {
        let terms = terms(of: query)
        guard !terms.isEmpty else { return nil }
        let url = TranscriptStore.transcriptURL(for: book, in: transcriptsDir)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(TranscriptFile.self, from: data) else { return nil }

        var matches: [TextMatch] = []
        var total = 0
        for chapter in book.chapters {
            guard let raw = file.chapters[chapter.fileURL.lastPathComponent] else { continue }
            for line in raw {
                guard let start = TranscriptStore.localStart(of: line.start, in: chapter, of: book.chapters),
                      isHit(line.text, terms: terms) else { continue }
                total += 1
                guard matches.count < perBookLimit else { continue }
                // 只有要列出来的句子才整理文字（去首尾空白、切高亮片段）
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                matches.append(TextMatch(bookID: book.id, chapterID: chapter.id,
                                         chapterTitle: chapter.title, start: start,
                                         segments: segments(of: text, terms: terms)))
            }
        }
        return TextBookHits(bookID: book.id, matches: matches, hidden: total - matches.count)
    }

    /// 关键词拆分：空格分开的几个词要同时出现在一句里才算命中（中文一般就是一整个短语）
    private static func terms(of query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 这一句命中了吗：每个关键词都必须在句里出现
    ///
    /// 只做判定、不分配任何字符串 —— 全库 25 万句每句都要走一遍这一步。
    private static func isHit(_ text: String, terms: [String]) -> Bool {
        for term in terms where ranges(of: term, in: text) == nil { return false }
        return true
    }

    /// 把一句切成高亮片段（命中的那段 marked=true）；传进来的文字必须已经判过命中
    private static func segments(of text: String, terms: [String]) -> [TextMatch.Segment] {
        var found: [Range<String.Index>] = []
        for term in terms { found.append(contentsOf: ranges(of: term, in: text) ?? []) }
        found.sort { $0.lowerBound < $1.lowerBound }

        var segments: [TextMatch.Segment] = []
        var cursor = text.startIndex
        for range in found {
            guard range.lowerBound >= cursor, range.upperBound > cursor else { continue }
            let plain = String(text[cursor..<range.lowerBound])
            if !plain.isEmpty { segments.append(.init(text: plain, marked: false)) }
            segments.append(.init(text: String(text[range.lowerBound..<range.upperBound]), marked: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(.init(text: String(text[cursor...]), marked: false))
        }
        return segments.isEmpty ? [.init(text: text, marked: false)] : segments
    }

    /// 句中所有关键词出现的位置（nil = 这句没命中）
    ///
    /// 三段代价不同的比对，按「先便宜后贵」排：
    /// 1. 原样整串包含 —— 全库 25 万句实测 276 ms，绝大多数命中都在这一步结束；
    /// 2. 折叠比对（不区分大小写、声调、全半角）—— 同一批数据要 1 秒，因为它逐字符走
    ///    Unicode 排序；只有词和句里都出现 ASCII 字母或数字时才补这一遍（写法差异只可能
    ///    出在这些字符上：搜「iphone」要能找到「iPhone」，搜「２００８」要能找到「2008」）；
    /// 3. 把句中空白挤掉再比 —— 转写与校对稿偶尔会在汉字中间夹进多余空格（全库只有 0.7%
    ///    的句子里有空格），漏掉这类句子就是「明明书里有，却说搜不到」的口碑事故。
    private static func ranges(of term: String, in text: String) -> [Range<String.Index>]? {
        if let found = occurrences(of: term, in: text, options: []) { return found }
        if hasFoldableCharacter(term), hasFoldableCharacter(text),
           let found = occurrences(of: term, in: text, options: foldOptions) { return found }
        guard text.utf8.contains(0x20) else { return nil }
        return collapsedRanges(of: term, in: text)
    }

    /// 这段文字里有没有「可能有另一种写法」的字符：ASCII 字母数字、全角字母数字、带音标的拉丁字母
    ///
    /// 汉字本身没有大小写与全半角之分（Unicode 把汉字算作字母，所以不能直接用 alphanumerics 判断），
    /// 纯中文关键词因此整趟跳过折叠比对 —— 这一步省下的正是全库搜索的那 0.7 秒。
    private static func hasFoldableCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            switch v {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,      // ASCII 数字、大小写字母
                 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A,   // 全角数字与字母
                 0x00C0...0x024F:                            // 带音标的拉丁字母（é ü ñ …）
                return true
            default:
                return false
            }
        }
    }

    /// 按给定选项找出词在句中的每一处出现
    private static func occurrences(of term: String, in text: String,
                                   options: String.CompareOptions) -> [Range<String.Index>]? {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let range = text.range(of: term, options: options, range: from..<text.endIndex) {
            found.append(range)
            from = range.upperBound
        }
        return found.isEmpty ? nil : found
    }

    /// 忽略空白后的比对，命中位置换算回原文（界面上要展示与高亮的仍是原文）
    private static func collapsedRanges(of term: String, in text: String) -> [Range<String.Index>]? {
        var kept: [Character] = []
        var positions: [String.Index] = []
        for index in text.indices where !text[index].isWhitespace {
            kept.append(text[index])
            positions.append(index)
        }
        let needle = term.filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return nil }

        let collapsed = String(kept)
        var found: [Range<String.Index>] = []
        var from = collapsed.startIndex
        while from < collapsed.endIndex,
              let range = collapsed.range(of: needle, options: foldOptions, range: from..<collapsed.endIndex) {
            let lower = collapsed.distance(from: collapsed.startIndex, to: range.lowerBound)
            let length = collapsed.distance(from: range.lowerBound, to: range.upperBound)
            from = range.upperBound
            guard length > 0, lower + length <= positions.count else { continue }
            // 命中段在原文里从第一个保留字符起、到最后一个保留字符止（中间的空格一起带上）
            found.append(positions[lower]..<text.index(after: positions[lower + length - 1]))
        }
        return found.isEmpty ? nil : found
    }
}
