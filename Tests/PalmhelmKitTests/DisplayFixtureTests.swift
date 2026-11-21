import Foundation
import Testing
@testable import PalmhelmKit

/// Bridge 导出的 Go 实际输出（Rules() → RecognizeHistory → JSON）：两端一致性的检验源。
/// 文件是 Bridge `internal/uimsg/testdata/display-fixture.json` 的副本；Bridge 更新后整份替换。
@Suite struct DisplayFixtureTests {
    struct Entry: Decodable { let name: String; let uuid: String; let text: String; let displayMessage: LossyDisplayMessage }

    static func load() throws -> [Entry] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/display-fixture.json")
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }

    @Test func everyBridgeEntryDecodesAndRendersInEnglish() throws {
        let entries = try Self.load()
        #expect(entries.count > 200)
        var failures: [String] = []
        for e in entries {
            guard let m = e.displayMessage.value else { failures.append("\(e.name): decode"); continue }
            if KitL10n.$locale.withValue(Locale(identifier: "en"), operation: { BridgeDisplayMessage.text(m) }) == nil { failures.append("\(e.name): render nil") }
        }
        #expect(failures.isEmpty, "\(failures.count) failed: \(failures.prefix(30))")
    }

    @Test func englishNeverLeavesAChineseSentenceExceptCommandLiterals() throws {
        for e in try Self.load() {
            guard let m = e.displayMessage.value, let out = KitL10n.$locale.withValue(Locale(identifier: "en"), operation: { BridgeDisplayMessage.text(m) }) else { continue }
            #expect(!out.contains("{") || e.text.contains("{"), "\(e.name) leaves a token: \(out)")
        }
    }
}
