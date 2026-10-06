import Foundation
import Testing

/// VoiceOver (UC-A11Y-01, W5-1b): a button, menu or toggle whose label is only a symbol needs an
/// `.accessibilityLabel` (the item's menu title). Walks `MLM/Views` for `Image(systemName:)` inside
/// a control's label and asks for a label, a hidden-decoration flag or text within the next lines.
@Suite("IconButtonLabelTests")
struct IconButtonLabelTests {
    private static var views: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MLM/Views")
    }

    @Test func everySymbolOnlyControlIsLabelled() throws {
        let files = FileManager.default.enumerator(at: Self.views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        let control = try NSRegularExpression(pattern: #"label:|\bMenu\b|\bButton\b|\bToggle\b"#)
        let answered = try NSRegularExpression(pattern: #"accessibilityLabel|accessibilityHidden|Text\(|Label\("#)
        var missing: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("Image(systemName") && !line.contains("Label(") {
                let back = lines[max(0, index - 3)...index].joined(separator: "\n")
                guard control.firstMatch(in: back, range: NSRange(back.startIndex..., in: back)) != nil else { continue }
                let forward = lines[index..<min(lines.count, index + 12)].joined(separator: "\n")
                if answered.firstMatch(in: forward, range: NSRange(forward.startIndex..., in: forward)) == nil {
                    missing.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(missing.isEmpty, "symbol-only controls without a label: \(missing)")
    }
}
