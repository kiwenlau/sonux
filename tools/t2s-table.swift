// 生成繁体→简体单字映射表：tools/t2s.json
//
// 为什么要它：源书是港台配音，whisper 转写出来繁简混杂（同一章里两句简体两句繁体），
// 直接上播放页字幕很难看。macOS/iOS 的 ICU 自带 Hant-Hans 转换，但 Python 侧调不到，
// 于是用这个脚本把系统数据一次性导出成表，转写工具按表逐字替换（离线、可重跑）。
//
// 用法：swift tools/t2s-table.swift > tools/t2s.json
import Foundation

var table: [String: String] = [:]
// 常用汉字区 + 兼容表意文字区，逐字问 ICU「转成简体后还是我吗」
for block in [0x4E00...0x9FFF, 0xF900...0xFAFF] {
    for code in block {
        guard let scalar = Unicode.Scalar(code) else { continue }
        let original = String(Character(scalar))
        let converted = NSMutableString(string: original)
        guard CFStringTransform(converted, nil, "Hant-Hans" as CFString, false) else { continue }
        let result = converted as String
        if result != original, result.count == 1 {
            table[original] = result
        }
    }
}
let data = try! JSONSerialization.data(withJSONObject: table, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardError.write("映射 \(table.count) 字\n".data(using: .utf8)!)
