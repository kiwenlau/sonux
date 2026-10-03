import Foundation

/// 一行字幕：音频时间轴上的起止秒 + 那一刻正在朗读的文案
struct TranscriptLine: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Documents/transcripts/<书>.json 的解码壳：`{"v":1,"chapters":{"章文件名":[[起,止,文],…]}}`
///
/// 每行存成三元数组而不是对象，是为了让字幕包尽量小（全库 34 本约 20 MB，
/// 逐章一个文件会让真机同步变成上千次传输）。键用章文件名而不是整条相对路径，
/// 因为同一本书目录内文件名不重复，而书库目录被改名后相对路径会整体失效。
struct TranscriptFile: Decodable {
    /// `[起, 止, 文]`：类型混杂的数组需要按位置手写解码
    struct RawLine: Decodable {
        let start: Double
        let end: Double
        let text: String

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            start = try container.decode(Double.self)
            end = try container.decode(Double.self)
            text = try container.decode(String.self)
        }
    }

    let chapters: [String: [RawLine]]

    private enum CodingKeys: String, CodingKey { case chapters }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapters = try container.decodeIfPresent([String: [RawLine]].self, forKey: .chapters) ?? [:]
    }

    /// 章文件名字符串转成按时间排好、去掉空句的字幕行；没有该章返回空数组
    func lines(forChapterFile name: String) -> [TranscriptLine] {
        let raw = chapters[name] ?? []
        return raw.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, line.end > line.start else { return nil }
            return TranscriptLine(start: line.start, end: line.end, text: text)
        }
        .sorted { $0.start < $1.start }
    }
}
