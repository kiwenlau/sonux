import Foundation

/// 一段可以跳过去的静音（章内秒）：从 from 起、跳到 to 落
struct SilenceGap: Equatable {
    let from: TimeInterval
    let to: TimeInterval
    /// 字幕上从上一句收尾到下一句开口的原始长度；档位阈值按它比，
    /// 两端各留一点保护才成了 from/to，免得贴着转写时间戳跳会啃掉字
    let span: TimeInterval
}

/// 静音地图：正文里没有台词的时段就是可以跳的时段。
///
/// 拿字幕的空档当静音判据，是为了省掉解码——一本十几小时的书要听完整本才能算完
/// 能量包络，而字幕早就躺在 Documents/transcripts 里，读完立刻知道后面哪儿有长停顿。
/// 代价是「没有台词」不等于「全无声」：章头的片头音乐也会被当成空档，
/// 但这类片段本来就是听众想跳过去的。
enum SilenceGaps {
    /// 上一句收尾后再多等这么多才算真停下来：转写的时间戳常比实际收声略早
    static let tailSlack: TimeInterval = 0.25
    /// 下一句开口前提前这么多落地：转写时间戳常比实际开口略晚，贴着跳会吃掉半个字头
    static let leadSlack: TimeInterval = 0.25
    /// 章尾留这么多彩蛋：跳得太贴近章尾会把「本章播完」抢在下一句之前判掉
    static let chapterTailGuard: TimeInterval = 0.5

    /// 某章的空档表，按 from 升序。没有字幕就没有地图，播放器完全不介入
    static func gaps(from lines: [TranscriptLine], chapterDuration: TimeInterval) -> [SilenceGap] {
        guard let first = lines.first, chapterDuration > 0 else { return [] }
        var result: [SilenceGap] = []

        // 章头：从 0 到第一句开口之前
        if first.start > leadSlack {
            result.append(SilenceGap(from: 0, to: first.start - leadSlack, span: first.start))
        }
        for (previous, next) in zip(lines, lines.dropFirst()) {
            let span = next.start - previous.end
            guard span > 0 else { continue }   // 转写偶有重叠，重叠处不算静音
            let from = previous.end + tailSlack
            let to = next.start - leadSlack
            if to > from { result.append(SilenceGap(from: from, to: to, span: span)) }
        }
        // 章尾：最后一句收声到本章结束前
        if let last = lines.last {
            let from = last.end + tailSlack
            let to = chapterDuration - chapterTailGuard
            let span = chapterDuration - last.end
            if span > 0, to > from { result.append(SilenceGap(from: from, to: to, span: span)) }
        }
        return result
    }

    /// 此刻正落在哪一段够长的静音里？返回该跳去的章内秒，不在静音里或空档太短返回 nil
    static func skipTarget(in gaps: [SilenceGap], at time: TimeInterval, minGap: TimeInterval) -> TimeInterval? {
        guard !gaps.isEmpty else { return nil }
        // 二分找「from ≤ time」的最后一个空档：静音只可能落在它里面，后面的都还在未来
        var low = 0
        var high = gaps.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if gaps[mid].from <= time { low = mid } else { high = mid - 1 }
        }
        let gap = gaps[low]
        // 落在第一段静音之前也算「不在静音里」：二分会把 low 停在 0，这里必须自己把边界守住
        guard time >= gap.from, time < gap.to, gap.span >= minGap else { return nil }
        return gap.to
    }
}
